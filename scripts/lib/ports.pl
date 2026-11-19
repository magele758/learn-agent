#!/usr/bin/env perl
# 端口工具，被 scripts/dev-ports.sh 与 .agents/hooks/guard-shell.sh 调用；只用 perl 核心模块。
#   ports.pl alloc <A-B> <段大小> <key> [protected-ports]  → "<起> <止> <顺延段数>"
#   ports.pl listening <起> <止>                           → 每行 "<端口> <pid> <进程名>"；没有 lsof / ss 时退出码 3
#   ports.pl guard [protected-ports] < hook 输入           → 命令会结束受保护端口上的进程时输出原因、退出码 1
# 本脚本只读：从不发送信号、不结束任何进程；查询进程只调用 lsof / ss / pgrep。
use strict;
use warnings;
use Digest::MD5 qw(md5);
use POSIX ();
use Text::ParseWords qw(shellwords);

sub protected { # <文件> <严格> → ([下限, 上限], …)：每行一个端口或区间，逗号 / 空白分隔多个，# 后为注释
  my ($file, $strict) = @_;
  my @r;
  return @r unless defined $file && -f $file;
  open(my $fh, '<', $file) or die "无法读取 $file：$!\n";
  while (my $l = <$fh>) {
    $l =~ s/#.*//s;
    for my $t (split /[\s,]+/, $l) {
      next if $t eq '';
      if ($t =~ /^(\d{1,5})(?:-(\d{1,5}))?$/) {
        my ($lo, $hi) = ($1, defined $2 ? $2 : $1);
        if ($lo >= 1 && $hi <= 65535 && $lo <= $hi) { push @r, [$lo, $hi]; next }
      }
      my $msg = "$file:$.：无法解析「$t」（写成 5432 或 3000-3003）";
      die "$msg\n" if $strict;
      warn "  ⚠ $msg\n";
    }
  }
  close $fh;
  return @r;
}

sub alloc {
  my ($range, $size, $key, $file) = @_;
  my ($lo, $hi) = $range =~ /^(\d{1,5})-(\d{1,5})$/;
  die "dev_ports_range 应写成 A-B（1–65535），当前：$range\n" unless defined $lo && $lo >= 1 && $hi <= 65535 && $lo <= $hi;
  die "dev_ports_block 应为正整数，当前：$size\n" unless $size =~ /^[1-9]\d{0,4}$/;
  my $n = int(($hi - $lo + 1) / $size);
  die "区间 $range 放不下一段 $size 个端口\n" if $n < 1;
  my @p = protected($file, 1);
  my $h = unpack('N', md5($key));
  for my $i (0 .. $n - 1) {
    my $base = $lo + (($h + $i) % $n) * $size;
    my $end = $base + $size - 1;
    next if grep { $_->[0] <= $end && $_->[1] >= $base } @p;
    print "$base $end $i\n";
    return;
  }
  die "区间 $range 的每一段都与受保护端口重叠：调整 dev_ports_range 或 .agents/protected-ports\n";
}

sub have { # <命令> → 可执行文件路径（PATH 之外再找 /usr/sbin、/sbin）
  my ($c) = @_;
  for my $d (split(/:/, defined $ENV{PATH} ? $ENV{PATH} : ''), '/usr/sbin', '/sbin') {
    return "$d/$c" if $d ne '' && -x "$d/$c";
  }
  return;
}

sub run_lines { # 不经过 shell 执行命令（stderr 丢弃），返回 stdout 各行
  my @cmd = map { my $x = $_; utf8::encode($x) if utf8::is_utf8($x); $x } @_;
  my $pid = open(my $fh, '-|');
  return () unless defined $pid;
  if (!$pid) {
    open(STDERR, '>', '/dev/null');
    exec { $cmd[0] } @cmd or POSIX::_exit(127);
  }
  my @out = <$fh>;
  close $fh;
  chomp @out;
  return @out;
}

sub listeners { # 本机处于 LISTEN 的 TCP 端口 → [[端口, pid, 进程名], …]；没有 lsof / ss 时返回 undef
  my @r;
  if (my $lsof = have('lsof')) {
    my ($pid, $name) = ('', '');
    for (run_lines($lsof, '-nP', '-iTCP', '-sTCP:LISTEN', '-Fpcn')) {
      if (/^p(\d+)/) { ($pid, $name) = ($1, '') }
      elsif (/^c(.*)/) { $name = $1 }
      elsif (/^n.*:(\d+)$/) { push @r, [$1, $pid, $name] }
    }
    return \@r;
  }
  if (my $ss = have('ss')) {
    for (run_lines($ss, '-ltnp')) {
      my @f = split ' ';
      next unless @f >= 4 && $f[3] =~ /:(\d+)$/;
      my $port = $1;
      my ($name, $pid) = /users:\(\("([^"]*)",pid=(\d+)/ ? ($1, $2) : ('', '');
      push @r, [$port, $pid, $name];
    }
    return \@r;
  }
  return;
}

sub listening {
  my ($lo, $hi) = @_;
  my $l = listeners() or exit 3;
  my %seen;
  for (sort { $a->[0] <=> $b->[0] } @$l) {
    my ($port, $pid, $name) = @$_;
    next if $port < $lo || $port > $hi || $seen{"$port $pid"}++;
    print "$port $pid $name\n";
  }
}

sub hook_command { # hook 的 JSON 输入（Cursor：command；Claude Code：tool_input.command）；不是 JSON 时按原文
  local $/;
  my $in = <STDIN>;
  $in = '' unless defined $in;
  if (eval { require JSON::PP; 1 }) {
    my $j = eval { JSON::PP->new->utf8->decode($in) };
    if (ref $j eq 'HASH') {
      my $c = ref $j->{tool_input} eq 'HASH' ? $j->{tool_input}{command} : $j->{command};
      return $c if defined $c && !ref $c;
    }
  }
  return $in;
}

my $KILL = qr/(?<![\w.-])(?:kill|pkill|killall|fkill|fkill-cli|xkill|kill-port)(?![\w-])/;
my $VERB = qr/$KILL|\bfuser\b[^\n;&|]*?\s-[A-Za-z]*k|\bss\b[^\n;&|]*?\s-[A-Za-z]*K|\bdocker\s+(?:container\s+)?(?:kill|stop|rm|restart)\b/;
my $ARGS = qr/([^\n;&|)`]*)/;

sub guard {
  my ($file) = @_;
  my @p = protected($file, 0);
  return 0 unless @p;
  my $cmd = hook_command();
  return 0 unless $cmd =~ $VERB;
  my $prot = sub { my $n = shift; return scalar grep { $n >= $_->[0] && $n <= $_->[1] } @p };

  # 1) 命令里写出的端口：:PORT、PORT/tcp、-n tcp PORT、--port / PORT=、docker publish=，以及 pkill 等的参数
  my @ports = $cmd =~ /:(\d{1,5})(?!\d)/g;
  push @ports, $cmd =~ /(?<!\d)(\d{1,5})\/(?:tcp|udp)\b/gi;
  push @ports, $cmd =~ /-n\s+(?:tcp|udp)\s+(\d{1,5})(?!\d)/gi;
  push @ports, $cmd =~ /\bports?["']?\s*[=:\s]\s*["']?(\d{1,5})(?!\d)/gi;
  push @ports, $cmd =~ /\b(?:publish|expose)=(\d{1,5})(?!\d)/gi;
  while ($cmd =~ /(?<![\w.-])(?:pkill|killall|pgrep|fkill|fkill-cli|kill-port)(?![\w-])$ARGS/g) {
    my $args = $1;
    push @ports, $args =~ /(?<![\w.-])(\d{2,5})(?![\w.])/g;
  }
  for my $n (@ports) {
    if ($prot->($n)) { print "结束受保护端口 $n 上的进程"; return 1 }
  }

  # 2) kill <pid> / pkill / killall / pgrep：查出目标 pid，看它们是否在监听受保护端口
  my (%pid, @queries);
  while ($cmd =~ /(?<![\w.-])(kill|pkill|killall|pgrep)(?![\w-])$ARGS/g) {
    my ($verb, $rest) = ($1, $2);
    my @a = shellwords($rest);
    if ($verb eq 'kill') {
      my ($probe, @ids) = (0);
      for (my $i = 0; $i < @a; $i++) {
        my $t = $a[$i];
        if ($t eq '-s' || $t eq '-n') { $probe = 1 if defined $a[$i + 1] && $a[$i + 1] eq '0'; $i++; next }
        if ($t eq '-0' || $t eq '-l' || $t eq '-L') { $probe = 1; next }
        push @ids, $t if $t =~ /^\d+$/;
      }
      if (!$probe) { $pid{$_} = 1 for @ids }
    } elsif ($verb eq 'killall') {
      push @queries, ['-x', $_] for grep { !/^-/ } @a;
    } else {
      my @q;
      for (my $i = 0; $i < @a; $i++) {
        my $t = $a[$i];
        if ($t eq '--signal') { $i++; next }
        next if $t =~ /^-(?:\d+|[A-Z][A-Z0-9+-]*|e|-echo|-signal=.*)$/;
        push @q, $t;
      }
      push @queries, \@q if grep { !/^-/ } @q;
    }
  }
  if (@queries && (my $pgrep = have('pgrep'))) {
    for my $q (@queries) { $pid{$_} = 1 for grep { /^\d+$/ && $_ != $$ } run_lines($pgrep, @$q) }
  }
  return 0 unless %pid;
  my $l = listeners() or return 0;
  for (@$l) {
    my ($port, $p, $name) = @$_;
    next unless $pid{$p} && $prot->($port);
    print "结束监听受保护端口 $port 的进程 $name（pid $p）";
    return 1;
  }
  return 0;
}

my $sub = shift @ARGV;
$sub = '' unless defined $sub;
if ($sub eq 'alloc' && @ARGV >= 3) { alloc(@ARGV); exit 0 }
if ($sub eq 'listening' && @ARGV == 2) { listening(@ARGV); exit 0 }
if ($sub eq 'guard') { exit guard(@ARGV) }
die "用法：ports.pl alloc <A-B> <段大小> <key> [protected-ports] | listening <起> <止> | guard [protected-ports]\n";
