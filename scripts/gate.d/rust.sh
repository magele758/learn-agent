# 技术栈适配：Rust（Cargo，单 crate 或 workspace）。

rust_detect() { manifest_dirs Cargo.toml; }

rust_lint() {
  if cargo fmt --version >/dev/null 2>&1; then
    echo "  \$ cargo fmt --all -- --check"; cargo fmt --all -- --check
  else
    echo "  · 未安装 rustfmt（跳过）"
  fi
  if cargo clippy --version >/dev/null 2>&1; then
    echo "  \$ cargo clippy --all-targets -- -D warnings"; cargo clippy --all-targets -- -D warnings
  else
    echo "  · 未安装 clippy（跳过）"
  fi
}

rust_unit() { echo "  \$ cargo test --workspace"; cargo test --workspace; }
rust_slow() { echo "  \$ cargo test --workspace -- --ignored"; cargo test --workspace -- --ignored; }
