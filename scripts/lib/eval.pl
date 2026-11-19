#!/usr/bin/env perl
# eval 层：参考 runner、结果校验与合并、基线对比、验收阈值。约定见 evals/README.md。
# 由 scripts/eval-run.sh、eval-compare.sh、check-acceptance.sh 调用，工作目录为仓库根；只用 perl 核心模块。
#   run --cmd <命令> [--timeout <秒>] [--cost-unit <单位>] <数据集>   参考 runner：标准 JSON → stdout
#   collect <输出> <数据集> <结果> [<数据集> <结果> …]               校验各数据集的标准 JSON，合并为 latest.json
#   compare <当前> <基线> [--update]                                  阈值来自环境变量 EVAL_*（由 eval-compare.sh 设置）
#   acceptance <引用> <latest.json> [fail|warn]                       引用文件每行：标签 \t 数据集 \t min_pass_rate
use strict;
use warnings;
use utf8;
use Cwd ();
use Encode qw(decode encode);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use POSIX qw(ceil strftime);
use Time::HiRes ();

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
@ARGV = map { decode('UTF-8', $_) } @ARGV;

my $J = JSON::PP->new->utf8->canonical->allow_nonref;   # 字节 ↔ 数据
my $C = JSON::PP->new->canonical->allow_nonref;         # 字符 ↔ 数据（判定、喂给被测命令）
my $PRETTY = JSON::PP->new->canonical->pretty;
my $EPS = 1e-9;
my $NOISE_MS = 50;   # p95 增量低于此值视为测量噪声，不判相对回退

sub usage_fail { print STDERR "$_[0]\n"; exit 2 }

sub slurp { my ($p) = @_; open(my $fh, '<:raw', $p) or return; local $/; my $b = <$fh>; return defined $b ? $b : '' }

sub read_json { # <路径> → 数据；读不到或不是 JSON 时 die
  my ($p) = @_;
  my $b = slurp($p);
  die "读不到 $p\n" unless defined $b;
  my $d;
  unless (eval { $d = $J->decode($b); 1 }) { (my $why = $@) =~ s/ at \S+ line \d+.*//s; die "$p 不是有效的 JSON：$why\n" }
  return $d;
}

sub write_json {
  my ($p, $d) = @_;
  make_path(dirname($p));
  open(my $fh, '>:encoding(UTF-8)', "$p.tmp") or die "无法写入 $p：$!\n";
  print $fh $PRETTY->encode($d);
  (close($fh) && rename("$p.tmp", $p)) or die "无法写入 $p：$!\n";
}

sub is_num { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?\z/ }
sub round { my ($v, $d) = @_; return 0 + sprintf("%.${d}f", $v) }
sub pct { return sprintf('%.1f%%', 100 * $_[0]) }
sub num { return sprintf('%.6g', $_[0]) }
sub clip { my ($s, $n) = @_; $s =~ s/\s+/ /g; $s =~ s/\A | \z//g; return length($s) > $n ? substr($s, 0, $n) . '…' : $s }
sub head_commit { my $h = `git rev-parse HEAD 2>/dev/null`; return defined $h && $h =~ /\A([0-9a-f]{40})\s*\z/ ? $1 : undef }

sub percentile { # 最近秩
  my ($q, @v) = @_;
  return 0 unless @v;
  my @s = sort { $a <=> $b } @v;
  my $i = ceil($q * @s) - 1;
  return $s[$i < 0 ? 0 : $i];
}

# ---------- 数据集 ----------
sub read_dataset { # <路径> [显示名] → [用例…]；格式不对时 die，逐行列出问题
  my ($p, $shown) = @_;
  $shown //= $p;
  open(my $fh, '<:raw', $p) or die "找不到数据集：$shown\n";
  my (@cases, @err, %seen);
  my $n = 0;
  while (my $l = <$fh>) {
    $n++;
    $l =~ s/\A\xEF\xBB\xBF// if $n == 1;
    next if $l =~ /\A\s*\z/;
    my $c;
    unless (eval { $c = $J->decode($l); 1 } && ref $c eq 'HASH') { push @err, "第 $n 行：不是 JSON 对象"; next }
    my @miss = grep { !exists $c->{$_} } qw(id input expected criteria);
    if (@miss) { push @err, "第 $n 行：缺少字段 " . join('、', @miss); next }
    my $id = $c->{id};
    if (!defined $id || ref $id || $id eq '') { push @err, "第 $n 行：id 必须是非空字符串"; next }
    if ($seen{$id}) { push @err, "第 $n 行：id「$id」与第 $seen{$id} 行重复"; next }
    $seen{$id} = $n;
    my $cr = $c->{criteria};
    if (!defined $cr || (ref $cr && ref $cr ne 'HASH')) { push @err, "第 $n 行：criteria 必须是字符串或对象"; next }
    push @cases, $c;
  }
  push @err, '没有任何用例' unless @cases || @err;
  die join('', map { "$shown $_\n" } @err) if @err;
  return \@cases;
}

# ---------- 参考 runner ----------
sub judge { # <criteria> <expected> <输出> → (是否通过, 原因)
  my ($cr, $exp, $out) = @_;
  my $m = ref $cr eq 'HASH' ? $cr->{match} : $cr;
  return (0, '参考 runner 需要 criteria.match（exact / contains / regex / json）') unless defined $m && !ref $m;
  (my $o = $out) =~ s/\A\s+|\s+\z//g;
  if ($m eq 'exact') {
    (my $e = (ref $exp || !defined $exp) ? $C->encode($exp) : "$exp") =~ s/\A\s+|\s+\z//g;
    return ($o eq $e ? 1 : 0, $o eq $e ? undef : '输出与 expected 不一致');
  }
  if ($m eq 'contains') {
    my @need = ref $exp eq 'ARRAY' ? @$exp : ($exp);
    return (0, 'contains 的 expected 必须是字符串或字符串列表') if grep { !defined $_ || ref $_ } @need;
    my @miss = grep { index($o, $_) < 0 } @need;
    return (@miss ? 0 : 1, @miss ? '输出缺少：' . join('、', @miss) : undef);
  }
  if ($m eq 'regex') {
    return (0, 'regex 的 expected 必须是字符串') if !defined $exp || ref $exp;
    my $re = eval { qr/$exp/ };
    return (0, '正则无效：' . clip($@, 120)) unless $re;
    return $o =~ $re ? (1, undef) : (0, '输出不匹配正则');
  }
  if ($m eq 'json') {
    my $got;
    return (0, '输出不是 JSON') unless eval { $got = $C->decode($o); 1 };
    return $C->encode($got) eq $C->encode($exp) ? (1, undef) : (0, 'JSON 与 expected 不相等');
  }
  return (0, "参考 runner 不支持 criteria「$m」（exact / contains / regex / json；其他判定用项目 runner）");
}

sub run_case { # <命令> <临时目录> <超时秒> <环境变量…> → (退出码, 是否超时)；stdin / stdout / stderr 为目录下的 in / out / err
  my ($cmd, $dir, $timeout, %env) = @_;
  my $pid = fork();
  die "fork 失败：$!\n" unless defined $pid;
  if (!$pid) {
    setpgrp(0, 0);
    (open(STDIN, '<', "$dir/in") && open(STDOUT, '>', "$dir/out") && open(STDERR, '>', "$dir/err")) or POSIX::_exit(126);
    $ENV{$_} = encode('UTF-8', $env{$_}) for keys %env;
    exec('/bin/sh', '-c', encode('UTF-8', $cmd)) or POSIX::_exit(127);
  }
  my $timed_out = 0;
  local $SIG{ALRM} = sub { my $sig = $timed_out++ ? 'KILL' : 'TERM'; kill $sig, -$pid, $pid; alarm 3 };
  alarm $timeout;
  waitpid($pid, 0);
  alarm 0;
  my $st = $?;
  return (($st & 127) ? 128 + ($st & 127) : $st >> 8, $timed_out);
}

sub cmd_run {
  my ($cmd, $ds, $timeout, $unit) = (undef, undef, 60, 'USD');
  my $usage = '用法：scripts/eval-run.sh --cmd <被测命令> [--timeout <秒>] [--cost-unit <单位>] <数据集.jsonl>';
  while (@_) {
    my $arg = shift;
    if ($arg eq '--cmd' || $arg eq '--timeout' || $arg eq '--cost-unit') {
      usage_fail("eval-run：$arg 需要一个值") unless @_;
      my $v = shift;
      if ($arg eq '--cmd') { $cmd = $v } elsif ($arg eq '--timeout') { $timeout = $v } else { $unit = $v }
    }
    elsif ($arg =~ /\A-/) { usage_fail("eval-run：未知参数 $arg（$usage）") }
    elsif (defined $ds) { usage_fail("eval-run：多余参数 $arg（$usage）") }
    else { $ds = $arg }
  }
  usage_fail($usage) unless defined $cmd && $cmd ne '' && defined $ds;
  usage_fail('eval-run：--timeout 必须是正整数（秒）') unless $timeout =~ /\A[1-9][0-9]*\z/;
  usage_fail('eval-run：--cost-unit 不能为空') if $unit eq '';
  my $root = decode('UTF-8', Cwd::getcwd());
  my $path = File::Spec->rel2abs($ds, $ENV{AEP_CALLER_PWD} ? decode('UTF-8', $ENV{AEP_CALLER_PWD}) : $root);
  my $shown = File::Spec->abs2rel($path, $root);
  $shown = $path if $shown =~ m{\A\.\.(?:/|\z)};
  my $cases = eval { read_dataset($path, $shown) };
  unless ($cases) { print STDERR $@; exit 2 }

  my $tmp = tempdir('aep-eval.XXXXXX', TMPDIR => 1, CLEANUP => 1);
  my (@out, @lat);
  my ($passed, $total) = (0, 0);
  for my $c (@$cases) {
    my $in = (ref $c->{input} || !defined $c->{input}) ? $C->encode($c->{input}) : $c->{input};
    open(my $fh, '>:raw', "$tmp/in") or die "无法写入临时文件：$!\n";
    print $fh encode('UTF-8', $in);
    close $fh;
    my $t0 = Time::HiRes::time();
    my ($rc, $timed_out) = run_case($cmd, $tmp, $timeout, AEP_EVAL_CASE_ID => "$c->{id}", AEP_EVAL_DATASET => $shown);
    my $ms = int((Time::HiRes::time() - $t0) * 1000 + 0.5);
    my $stdout = decode('UTF-8', slurp("$tmp/out") // '');
    my ($cost, @log);
    for my $l (split /\n/, decode('UTF-8', slurp("$tmp/err") // '')) {
      if ($l =~ /\AAEP_EVAL_COST=([0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)\s*\z/) { $cost = ($cost // 0) + $1 }
      elsif ($l =~ /\S/) { push @log, $l }
    }
    my ($ok, $why) = (0, undef);
    if ($timed_out) { $why = "超时（超过 $timeout 秒）" }
    elsif ($rc != 0) { $why = "被测命令退出码 $rc" . (@log ? '：' . clip($log[-1], 200) : '') }
    else { ($ok, $why) = judge($c->{criteria}, $c->{expected}, $stdout) }
    my %r = (id => "$c->{id}", pass => $ok ? JSON::PP::true : JSON::PP::false, latency_ms => $ms);
    $r{error} = $why if defined $why;
    $r{output} = clip($stdout, 200) if !$ok && !$timed_out && $rc == 0;
    if (defined $cost) { $r{cost} = round($cost, 6); $total += $cost }
    $passed++ if $ok;
    push @lat, $ms;
    push @out, \%r;
  }
  print $PRETTY->encode({
    dataset   => $shown,
    runner    => 'scripts/eval-run.sh',
    pass_rate => round($passed / @$cases, 4),
    cases     => \@out,
    cost      => { total => round($total, 6), unit => $unit },
    latency   => { p50_ms => percentile(0.5, @lat), p95_ms => percentile(0.95, @lat) },
  });
}

# ---------- 结果 ----------
sub check_result { # 标准 JSON → 问题列表
  my ($r) = @_;
  return ('顶层必须是对象') unless ref $r eq 'HASH';
  my @e;
  push @e, 'pass_rate 必须是 0–1 的数字' unless is_num($r->{pass_rate}) && $r->{pass_rate} >= 0 && $r->{pass_rate} <= 1;
  if (ref $r->{cases} ne 'ARRAY' || !@{ $r->{cases} }) { push @e, 'cases 必须是非空列表' }
  else {
    my $i = 0;
    for my $c (@{ $r->{cases} }) {
      my $w = 'cases[' . $i++ . ']';
      if (ref $c ne 'HASH') { push @e, "$w 必须是对象"; next }
      push @e, "$w.id 必须是非空字符串" if !defined $c->{id} || ref $c->{id} || $c->{id} eq '';
      push @e, "$w.pass 必须是 true / false" unless JSON::PP::is_bool($c->{pass});
      for my $k (qw(score cost latency_ms)) { push @e, "$w.$k 必须是数字" if defined $c->{$k} && !is_num($c->{$k}) }
      push @e, "$w.error 必须是字符串" if defined $c->{error} && ref $c->{error};
    }
  }
  my ($c, $l) = ($r->{cost}, $r->{latency});
  push @e, 'cost 必须是 {"total": ≥ 0 的数字, "unit": 单位}'
    unless ref $c eq 'HASH' && is_num($c->{total}) && $c->{total} >= 0 && defined $c->{unit} && !ref $c->{unit} && $c->{unit} ne '';
  push @e, 'latency 必须是 {"p50_ms": 数字, "p95_ms": 数字}' unless ref $l eq 'HASH' && is_num($l->{p50_ms}) && is_num($l->{p95_ms});
  return @e;
}

sub cmd_collect {
  my ($out, @pairs) = @_;
  usage_fail('用法：eval.pl collect <输出> <数据集> <结果> […]') unless defined $out && @pairs && @pairs % 2 == 0;
  my (%ds, @err);
  while (my ($d, $f) = splice(@pairs, 0, 2)) {
    my $r = eval { read_json($f) };
    unless (defined $r) { push @err, "$d：" . ($@ ? $@ =~ s/\n\z//r : 'runner 输出的是 null'); next }
    my @e = check_result($r);
    if (@e) { push @err, map { "$d 的结果不符合约定：$_" } @e; next }
    $r->{dataset} = $d;
    $ds{$d} = $r;
  }
  if (@err) { print map({ "  ✗ $_\n" } @err), "  （runner 的输出约定见 evals/README.md「标准 JSON」）\n"; exit 1 }
  write_json($out, { format => 1, generated => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime), commit => head_commit(), datasets => \%ds });
}

sub load_current { # latest.json 或单个数据集的标准 JSON → ({ 数据集 => 结果 }, 是否为全量)
  my ($p) = @_;
  my $r = read_json($p);
  my (%ds, $all);
  if (ref $r eq 'HASH' && ref $r->{datasets} eq 'HASH') { %ds = %{ $r->{datasets} }; $all = 1 }
  elsif (ref $r eq 'HASH' && (exists $r->{pass_rate} || exists $r->{cases})) {
    die "$p 是单个数据集的结果，但没有 dataset 字段\n" if !defined $r->{dataset} || ref $r->{dataset} || $r->{dataset} eq '';
    %ds = ($r->{dataset} => $r);
  }
  else { die "$p 既不是 latest.json（datasets）也不是标准结果（pass_rate），约定见 evals/README.md\n" }
  my @e = map { my $d = $_; map { "$d：$_" } check_result($ds{$d}) } sort keys %ds;
  die join('', map { "$p 不符合约定：$_\n" } @e) if @e;
  return (\%ds, $all);
}

sub limit { # <环境变量> <配置键> → 数字；空或 off 返回 undef（不检查）
  my ($env, $key) = @_;
  my $v = $ENV{$env} // '';
  $v =~ s/\A\s+|\s+\z//g;
  return undef if $v eq '' || $v =~ /\A(?:off|none|-)\z/i;
  usage_fail("eval-compare：$key 必须是非负数字或 off（当前：$v）") unless is_num($v) && $v >= 0;
  return $v;
}

sub cmd_compare {
  my ($cur_p, $base_p, @opt) = @_;
  usage_fail('用法：eval.pl compare <当前> <基线> [--update]') unless defined $base_p;
  my $update = grep { $_ eq '--update' } @opt;
  my %lim = (
    drop => limit('EVAL_MAX_DROP', 'eval_max_pass_rate_drop'), cost_inc => limit('EVAL_MAX_COST_INC', 'eval_max_cost_increase'),
    p95_inc => limit('EVAL_MAX_P95_INC', 'eval_max_p95_increase'), cost => limit('EVAL_MAX_COST', 'eval_max_cost'),
    p95 => limit('EVAL_MAX_P95_MS', 'eval_max_p95_ms'),
  );
  my $on = $ENV{EVAL_ON_BUDGET} // 'fail';
  usage_fail("eval-compare：eval_on_budget 只能是 fail 或 warn（当前：$on）") unless $on eq 'fail' || $on eq 'warn';

  my ($cur, $all) = eval { load_current($cur_p) };
  unless ($cur) { print "  ✗ $_\n" for split /\n/, $@; exit 1 }
  my ($base, $meta) = ({}, {});
  if (-e $base_p) {
    $meta = eval { read_json($base_p) };
    if (!$meta || ref $meta ne 'HASH' || ref($meta->{datasets} // {}) ne 'HASH') {
      print '  ✗ ', ($@ ? $@ =~ s/\n\z//r : "$base_p 不是基线格式（{\"format\": 1, \"datasets\": {…}}）"), "\n";
      exit 2;
    }
    $base = $meta->{datasets} // {};
    print "  基线：$base_p", ($meta->{updated} ? "（$meta->{updated}" . ($meta->{commit} ? " · $meta->{commit}" : '') . '）' : ''), "\n";
  }
  else { print "  基线：$base_p 不存在，全部按「没有基线」处理\n" }

  my ($fails, $warns) = (0, 0);
  my $bad = sub { $fails++; print "  ✗ $_[0]\n" };
  my $budget = sub { if ($on eq 'warn') { $warns++; print "  ⚠ $_[0]（eval_on_budget=warn，只告警）\n" } else { $bad->($_[0]) } };
  for my $d (sort keys %$cur) {
    my ($c, $bl) = ($cur->{$d}, $base->{$d});
    $bl = undef unless ref $bl eq 'HASH' && is_num($bl->{pass_rate});
    my ($cc, $cp) = ($c->{cost}, $c->{latency}{p95_ms});
    my ($bc, $bp) = $bl ? ($bl->{cost}, ref $bl->{latency} eq 'HASH' ? $bl->{latency}{p95_ms} : undef) : ();
    printf "  · %s：通过率 %s%s，成本 %s %s%s，p95 %s ms%s\n", $d,
      pct($c->{pass_rate}), $bl ? '（基线 ' . pct($bl->{pass_rate}) . '）' : '',
      num($cc->{total}), $cc->{unit}, ref $bc eq 'HASH' && is_num($bc->{total}) ? '（基线 ' . num($bc->{total}) . '）' : '',
      num($cp), is_num($bp) ? '（基线 ' . num($bp) . '）' : '';
    if (!$bl) { print "    没有基线：确认结果后用 scripts/eval-compare.sh --update-baseline 建立\n" unless $update }
    else {
      my $drop = $bl->{pass_rate} - $c->{pass_rate};
      $bad->(sprintf('%s：通过率比基线低 %.1f 个百分点，超过阈值 %.1f（eval_max_pass_rate_drop）', $d, 100 * $drop, 100 * $lim{drop}))
        if defined $lim{drop} && $drop > $lim{drop} + $EPS;
      if (ref $bl->{cases} eq 'HASH') {
        my %now = map { ("$_->{id}" => ($_->{pass} ? 1 : 0)) } @{ $c->{cases} };
        my @nf = sort grep { $bl->{cases}{$_} && exists $now{$_} && !$now{$_} } keys %{ $bl->{cases} };
        printf "    基线通过、本次失败（%d 条）：%s\n", scalar @nf, join(', ', @nf > 10 ? (@nf[0 .. 9], '…') : @nf) if @nf;
      }
      if (defined $lim{cost_inc} && ref $bc eq 'HASH' && is_num($bc->{total}) && $bc->{total} > 0) {
        if (($bc->{unit} // '') ne $cc->{unit}) { $warns++; print "  ⚠ $d：成本单位与基线不同（$cc->{unit} / " . ($bc->{unit} // '空') . "），跳过相对比较\n" }
        elsif ($cc->{total} > $bc->{total} * (1 + $lim{cost_inc}) + $EPS) {
          $budget->(sprintf('%s：成本比基线高 %.0f%%，超过 %.0f%%（eval_max_cost_increase）', $d, 100 * ($cc->{total} / $bc->{total} - 1), 100 * $lim{cost_inc}));
        }
      }
      if (defined $lim{p95_inc} && is_num($bp) && $bp > 0 && $cp - $bp >= $NOISE_MS && $cp > $bp * (1 + $lim{p95_inc}) + $EPS) {
        $budget->(sprintf('%s：延迟 p95 比基线高 %.0f%%，超过 %.0f%%（eval_max_p95_increase）', $d, 100 * ($cp / $bp - 1), 100 * $lim{p95_inc}));
      }
    }
    $budget->(sprintf('%s：成本 %s %s 超过上限 %s（eval_max_cost）', $d, num($cc->{total}), $cc->{unit}, num($lim{cost})))
      if defined $lim{cost} && $cc->{total} > $lim{cost} + $EPS;
    $budget->(sprintf('%s：延迟 p95 %s ms 超过上限 %s ms（eval_max_p95_ms）', $d, num($cp), num($lim{p95})))
      if defined $lim{p95} && $cp > $lim{p95} + $EPS;
  }
  if ($all) {
    for my $d (sort grep { !$cur->{$_} } keys %$base) {
      print "  · $d：基线里有、本次没有结果", (-e $d ? '' : '（数据集已删除，--update-baseline 时移出基线）'), "\n";
    }
  }

  if ($update) {
    my %nb = map { ($_ => $base->{$_}) } grep { -e $_ && !$cur->{$_} } keys %$base;
    for my $d (keys %$cur) {
      my $c = $cur->{$d};
      $nb{$d} = {
        pass_rate => $c->{pass_rate}, cost => { total => $c->{cost}{total}, unit => $c->{cost}{unit} },
        latency => { p50_ms => $c->{latency}{p50_ms}, p95_ms => $c->{latency}{p95_ms} },
        cases => { map { ("$_->{id}" => $_->{pass} ? JSON::PP::true : JSON::PP::false) } @{ $c->{cases} } },
      };
    }
    my $h = head_commit();
    write_json($base_p, { format => 1, updated => strftime('%Y-%m-%d', gmtime), (defined $h ? (commit => substr($h, 0, 12)) : ()), datasets => \%nb });
    print "  已更新基线 $base_p（", scalar(keys %$cur), ' 个数据集', $fails ? "，接受了上面 $fails 项回退" : '', '）：提交时在 commit / PR 里写明原因', "\n";
    exit 0;
  }
  if ($fails) { print "  eval 对比：$fails 项不通过\n"; exit 1 }
  printf "  eval 对比：通过（%d 个数据集%s）\n", scalar keys %$cur, $warns ? "，$warns 项警告" : '';
}

# ---------- 验收 ----------
sub cmd_acceptance {
  my ($refs, $latest, $mode) = @_;
  usage_fail('用法：eval.pl acceptance <引用> <latest.json> [fail|warn]') unless defined $refs;
  $mode //= 'fail';
  my ($res, $stale);
  if (defined $latest && -e $latest) {
    my $l = eval { read_json($latest) };
    if (ref $l eq 'HASH' && ref $l->{datasets} eq 'HASH') {
      $res = $l->{datasets};
      my $h = head_commit();
      $stale = !(defined $h && defined $l->{commit} && $l->{commit} eq $h);
    }
    else { print "  ⚠ $latest 无法读取，跳过 eval 阈值检查\n" }
  }
  open(my $fh, '<:encoding(UTF-8)', $refs) or usage_fail("读不到 $refs");
  my ($fail, $waiting, %lint) = (0, 0);
  while (my $line = <$fh>) {
    chomp $line;
    my ($label, $ds, $min) = split /\t/, $line, -1;
    next unless defined $ds && $ds ne '';
    $min //= '';
    $lint{$ds} //= eval { read_dataset($ds); '' } // $@;
    if ($lint{$ds} ne '') { print "✗ $label 引用的数据集格式不对：\n", map { "    $_\n" } split /\n/, $lint{$ds}; $fail = 1; next }
    next if $min eq '';
    unless (is_num($min) && $min >= 0 && $min <= 1) { print "✗ $label 的 min_pass_rate 必须是 0–1 的数字（当前：$min）\n"; $fail = 1; next }
    my $r = $res ? $res->{$ds} : undef;
    unless (ref $r eq 'HASH' && is_num($r->{pass_rate})) { $waiting++; next }
    next if $r->{pass_rate} + $EPS >= $min;
    my $msg = sprintf('%s：eval 通过率 %s 低于 min_pass_rate %s（%s）', $label, pct($r->{pass_rate}), pct($min), $ds);
    if ($stale) { print "  ⚠ $msg；$latest 不是当前提交生成的，只提示（重新运行 scripts/eval-compare.sh --run）\n" }
    elsif ($mode eq 'warn') { print "  ⚠ $msg；这里只提示，scripts/eval-compare.sh --run 之后按阈值判定\n" }
    else { print "✗ $msg\n"; $fail = 1 }
  }
  print "  · $waiting 条 eval 阈值还没有结果可查（scripts/eval-compare.sh --run 之后检查）\n" if $waiting;
  exit $fail;
}

my $sub = shift @ARGV // '';
if    ($sub eq 'run')        { cmd_run(@ARGV) }
elsif ($sub eq 'collect')    { cmd_collect(@ARGV) }
elsif ($sub eq 'compare')    { cmd_compare(@ARGV) }
elsif ($sub eq 'acceptance') { cmd_acceptance(@ARGV) }
else { usage_fail('用法：eval.pl run | collect | compare | acceptance …（见文件头注释）') }
