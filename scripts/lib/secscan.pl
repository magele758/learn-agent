#!/usr/bin/env perl
# 内置敏感信息扫描（没装 gitleaks 时兜底密钥，私有信息始终由这里检查）。由 scripts/lib/security.sh 调用，只用核心模块。
# 用法：secscan.pl --input grep|diff|message|messages [--label L] [--no-secrets]
#   grep：git grep -n 的输出（路径:行号:内容）；diff：git diff / git log -p 的输出（“commit <sha>” 行标记提交）
#   message：一条提交信息原文；messages：git log -z --format='%H%n%B' 的输出（多条，NUL 分隔）
# 提交信息与内容的差别：私网 IP（10/8、172.16/12、192.168/16）与 *.internal / *.lan / *.local
#   在提交信息里拦截；在代码里常是合法配置，diff 只告警（⚠，不算失败），全量扫描不报。
# 环境变量：AEP_PRIVATE_PATTERNS（仓库外的私有模式文件）、AEP_SECURITY_ALLOWLIST（项目豁免）、AEP_MAX_SUBJECT
# 输出只给位置、类别和打码后的片段，不回显完整的密钥或私有值。
use strict;
use warnings;
use utf8;
use Encode qw(decode);

binmode STDOUT, ':encoding(UTF-8)';
my ($input, $label, $secrets) = ('grep', '', 1);
while (@ARGV) {
  my $a = shift @ARGV;
  if ($a eq '--input') { $input = shift(@ARGV) // '' }
  elsif ($a eq '--label') { $label = decode('UTF-8', shift(@ARGV) // '') }
  elsif ($a eq '--no-secrets') { $secrets = 0 }
  else { die "secscan: unknown argument $a\n" }
}
die "secscan: unknown input $input\n" unless $input =~ /^(?:grep|diff|message|messages)$/;

sub read_list { # 每行一个正则（大小写不敏感，# 开头为注释）→ [行号, 正则]
  my ($f) = @_;
  return () unless $f && -f $f;
  open my $fh, '<', $f or return ();
  my ($n, @r) = (0);
  while (my $l = <$fh>) {
    $n++;
    $l = decode('UTF-8', $l);
    $l =~ s/\r?\n\z//;
    next if $l =~ /^\s*(?:#|$)/;
    my $re = eval { qr/$l/i };
    push @r, [ $n, $re ] if $re;
  }
  return @r;
}
my @allow = map { $_->[1] } read_list($ENV{AEP_SECURITY_ALLOWLIST});
my @private = read_list($ENV{AEP_PRIVATE_PATTERNS});
my $max_subject = $ENV{AEP_MAX_SUBJECT} || 100;

my $skip_path = qr{(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|poetry\.lock|uv\.lock|Gemfile\.lock|go\.sum|\.agents/security-allowlist)$};
my $placeholder = qr/example|placeholder|change-?me|your|xxxx|dummy|fake|test|replace|redacted|sample|todo|\$\{|^<|\*\*\*/i;
my @secret_rules = (
  [ '私钥', qr/-----BEGIN [A-Z ]*PRIVATE KEY-----/ ],
  [ 'AWS access key', qr/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ ],
  [ 'GitHub token', qr/\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})/ ],
  [ 'API key（sk-）', qr/\bsk-(?:proj-|ant-|live-)?[A-Za-z0-9_-]{32,}/ ],
  [ 'Slack token', qr/\bxox[abprs]-[A-Za-z0-9-]{10,}/ ],
  [ 'Google API key', qr/\bAIza[0-9A-Za-z_-]{35}\b/ ],
  [ 'JWT', qr/\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/ ],
);
my $generic = qr/(?:api[_-]?key|secret|token|passw(?:or)?d|private[_-]?key)[A-Za-z0-9_-]*["']?\s*[:=]\s*["']?([A-Za-z0-9\/+_=-]{16,})/i;
# 前面不是字母数字或点（v10.0.0.1 这类版本号不算）；后面不再接数字；网段写法（10.0.0.0/8）不算具体主机
my $ip_start = qr/(?<![0-9A-Za-z_.])/;
my $ip_end = qr/(?!\.?\d)(?!(?<=\.0)\/\d)/;
my $cgnat = qr/${ip_start}100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}$ip_end/;
my $private_ip = qr/${ip_start}(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}$ip_end/;
my $host_start = qr/(?<![A-Za-z0-9_.-])/;
my $host_end = qr/(?![A-Za-z0-9_-])(?!\.[A-Za-z0-9])/;
my $tailnet = qr/$host_start(?:[A-Za-z0-9-]+\.)+ts\.net$host_end/i;
my $lan_host = qr/$host_start(?:[A-Za-z0-9-]+\.)+(?:internal|lan|local)$host_end/i;
my $public_host = qr/example|^localhost\.|(?:^|\.)(?:docker\.internal|google\.internal|cluster\.local)$/i;
my $home_path = qr{/(Users|home)/([A-Za-z0-9._-]+)/};
my $generic_home = qr/^(?:example|user|username|you|me|name|someone|shared|runner|linuxbrew|ubuntu|node|vscode|x+|foo|bar|demo)$/i;
my $agent_reply = qr/完美|太好了|好的[，,!！]|已为您|为您(?:完成|修复|实现|处理)|让我|Verdict:|Rebase completed|\bI(?: have|'ve| will|'ll)\b|\bLet me\b|\bHere(?:'s| is)\b|\bSure[,!]/i;

my $found = 0;
sub mask_ip { my ($v) = @_; $v =~ s/^(\d+)\..*/$1.x.x.x/; return $v }
sub emit {
  my ($mark, $where, $kind, $snippet) = @_;
  print "  $mark " . ($label ne '' ? "$label " : '') . "$where [$kind]" . (defined $snippet ? " $snippet" : '') . "\n";
}
sub report { $found++; emit('✗', @_) }
sub notice { emit('⚠', @_) }

sub scan_line { # <message|diff|grep> <位置> <路径> <内容>
  my ($mode, $where, $path, $text) = @_;
  return if $path ne '' && $path =~ $skip_path;
  return if $mode ne 'message' && $text =~ /gitleaks:allow/;
  for my $re (@allow) { return if "$path:$text" =~ $re || $text =~ $re }
  if ($secrets) {
    for my $r (@secret_rules) {
      if ($text =~ $r->[1]) { report($where, $r->[0], substr($&, 0, 4) . '***'); last }
    }
    while ($text =~ /$generic/g) {
      my $v = $1;
      next if $v =~ $placeholder || $v =~ /^(.)\1+$/;
      report($where, '疑似密钥赋值', substr($v, 0, 4) . '***');
      last;
    }
  }
  report($where, 'Tailscale IP（100.64/10）', mask_ip($&)) if $text =~ $cgnat;
  while ($text =~ /$tailnet/g) {
    next if $& =~ /example/i;
    report($where, 'tailnet 主机名', '*.ts.net');
    last;
  }
  if ($mode ne 'grep') {
    my ($flag, $tag) = $mode eq 'message' ? (\&report, '') : (\&notice, '，仅告警');
    $flag->($where, "私网 IP$tag", mask_ip($&)) if $text =~ $private_ip;
    while ($text =~ /$lan_host/g) {
      my $h = $&;
      next if $h =~ $public_host;
      (my $tld = $h) =~ s/.*\././;
      $flag->($where, "内网主机名$tag", "*$tld");
      last;
    }
  }
  while ($text =~ /$home_path/g) {
    next if $2 =~ $generic_home;
    report($where, '个人绝对路径', "/$1/<name>/");
    last;
  }
  for my $p (@private) {
    if ($text =~ $p->[1]) { report($where, '私有模式', "private-patterns.txt 第 $p->[0] 行"); last }
  }
}

sub scan_message { # 提交信息的各行（已去掉注释行）
  my @lines = @_;
  my ($subject) = grep { /\S/ } @lines;
  $subject //= '';
  report('标题', '疑似 agent 回复原文', '请改写为用户视角的一句话') if $subject =~ $agent_reply;
  if (length($subject) > $max_subject && $subject !~ /^(?:Merge|Revert) /) {
    report('标题', '标题过长', length($subject) . " 字 > $max_subject");
  }
  scan_line('message', '第 ' . ($_ + 1) . ' 行', '', $lines[$_]) for 0 .. $#lines;
}

if ($input eq 'grep') {
  while (my $l = <STDIN>) {
    $l = decode('UTF-8', $l);
    chomp $l;
    my ($path, $n, $text) = $l =~ /^([^:]+):(\d+):(.*)$/ or next;
    scan_line('grep', "$path:$n", $path, $text);
  }
} elsif ($input eq 'diff') {
  my ($commit, $path, $n, $header) = ('', '', 0, 0);
  while (my $l = <STDIN>) {
    $l = decode('UTF-8', $l);
    chomp $l;
    if ($l =~ /^commit ([0-9a-f]{7,})/) { $commit = substr($1, 0, 7); next }
    if ($l =~ /^diff --git /) { $header = 1; $path = ''; next }
    if ($header) {
      if ($l =~ m{^\+\+\+ (?:b/)?(.*)$}) { $path = $1 eq '/dev/null' ? '' : $1 }
      $header = 0 if $l =~ /^@@/;
    }
    if ($l =~ /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/) { $n = $1; next }
    next if $header || $path eq '' || $l !~ /^\+(.*)$/;
    scan_line('diff', ($commit ne '' ? "$commit " : '') . "$path:$n", $path, $1);
    $n++;
  }
} elsif ($input eq 'message') {
  scan_message(map { my $x = decode('UTF-8', $_); $x =~ s/\r?\n\z//; $x } <STDIN>);
} else {
  local $/ = "\0";
  while (my $rec = <STDIN>) {
    chomp $rec;
    $rec = decode('UTF-8', $rec);
    my ($sha, $body) = $rec =~ /\A\n*([0-9a-f]{7,})\n(.*)\z/s or next;
    $label = 'commit ' . substr($sha, 0, 7);
    scan_message(split /\r?\n/, $body);
  }
}
exit($found ? 1 : 0);
