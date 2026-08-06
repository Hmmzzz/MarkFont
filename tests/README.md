# MarkFont 本地测试

从当前仓库运行：

```bash
./tests/run
```

调用链固定为：

```text
markfont/tests/run
  -> ../../scripts/jb-env
  -> xcrun clang + 当前 markfont/shared
  -> 当前 markfont/tests
```

父项目的 `scripts/jb-build`、`scripts/test-font-manager-core` 和旧仓库均不修改。
整个 `tests/` 由当前仓库 `.git/info/exclude` 忽略，只作为本机回归资产。
