# chez.nvim

[English](README.md) | 简体中文

为 Neovim 提供 Chez Scheme 支持：缩进、高亮、带内联结果的 REPL、补全、文档、宏展开和诊断。

- **缩进**：可处理不完整的代码，提供 Chez 形式（`library`、`syntax-case`、`fluid-let`、`trace-lambda` 等）的缩进规则，以及格式化工具（`:Chez format`、conform.nvim）。
- **高亮**：针对 Chez 语法、所有 (chezscheme) 过程、`#!chezscheme`、`#%car` 和 `#;` 数据注释的 tree-sitter 查询扩展。
- **REPL**：每个项目独立运行；可对形式、顶层形式、选区、缓冲区或文件求值；结果以虚拟文本显示，程序输出显示在 REPL 窗口中；`(read)` 由 Neovim 响应；可通过 SIGINT 中断；回溯信息可导入 quickfix；在失败的调用处显示诊断；自动导入已求值的库；提供带历史记录的提示符缓冲区。
- **补全**：blink.cmp 源和 `omnifunc`——支持作用域内的局部变量、缓冲区中的定义（包括记录构造器和访问器）、(chezscheme) 以及 REPL 绑定。
- **文档**：`K` 可显示 1585 个标识符的签名，以及来自《Chez Scheme 用户指南》和 R6RS 报告的文档；支持缓冲区定义及其注释、REPL 绑定、签名帮助和在线指南链接。
- **导航**：`gd` 可通过缓冲区、REPL 源位置和 ripgrep 跳转。
- **宏展开**：在浮动窗口中执行 `expand` 和 `expand/optimize`（cp0）。
- **诊断**：检查器进程会展开缓冲区内容（但不运行），在打开、保存以及编辑后（离开插入模式、普通模式修改，带防抖）报告语法错误和未绑定标识符，无需先保存。
- **括号**：输入 `(`/`)` 时是否配对、是否跳过右括号，根据整个顶层形式的括号平衡判断，而不是只看当前行（修复自动配对插件导致右括号丢失的问题）。

## 环境要求

- Neovim ≥ 0.11
- Chez Scheme（已使用 10.3.0 测试）
- tree-sitter `scheme` 解析器（`:TSInstall scheme`）
- 可选：blink.cmp、which-key.nvim、conform.nvim、ripgrep

## 安装（LazyVim / lazy.nvim）

`lua/plugins/chez.lua`：

```lua
return {
  {
    "Acomage/chez.nvim",
    ft = "scheme",
    opts = {},
  },

  -- 补全
  {
    "saghen/blink.cmp",
    opts = {
      sources = {
        per_filetype = {
          scheme = { inherit_defaults = true, "chez" },
          chez_repl = { "chez", "buffer" },
        },
        providers = {
          chez = { name = "Chez", module = "chez.complete.blink" },
        },
      },
    },
  },

  -- 结构化编辑，使用 chez.nvim 的规则重新缩进
  {
    "julienvincent/nvim-paredit",
    ft = "scheme",
    opts = function()
      return { indent = { enabled = true, indentor = require("chez.paredit").indentor } }
    end,
  },

  -- <leader>cf 使用 chez.nvim 的缩进器进行格式化
  {
    "stevearc/conform.nvim",
    opts = function(_, opts)
      opts.formatters = opts.formatters or {}
      opts.formatters.chez_indent = require("chez.format").conform
      opts.formatters_by_ft = opts.formatters_by_ft or {}
      opts.formatters_by_ft.scheme = { "chez_indent" }
    end,
  },
}
```

然后执行一次 `:TSInstall scheme`，再执行 `:checkhealth chez`。

键位是缓冲区局部的，位于 `<localleader>`（LazyVim 中为 `\`）之下：`e` 求值、`c` REPL、`m` 宏展开、`t` 跟踪、`h` 帮助；另有 `K`、`gd`，以及插入模式下的 `<C-k>`。nvim-paredit 会添加自己的键位（`>)`、`<(`、`>e`、`<localleader>o`、`<localleader>r` 等）。

配置、键位映射和命令请参见 `:help chez.nvim`。

## 开发

```sh
make test       # Scheme 和 Lua（plenary）测试
make generate   # 根据已安装的 Chez 生成 data/builtins.json 和 queries/scheme/highlights.scm
make docs CSUG=… CSUG_HTML=… R6RS=…   # 生成 data/docs.json，参见 scripts/gen-docs.lua
```

## 目录结构

```
after/ftplugin/scheme.lua   附加到 Chez 缓冲区
ftdetect/chez.lua           *.sls / *.sps / *.sch
queries/scheme/             高亮扩展（生成）
lua/chez/                   Neovim 端（缩进、repl/、complete/、文档、工具、诊断）
scheme/chez-nvim/           Chez 端：JSON、REPL 服务器、检查器
data/                       builtins.json、docs.json（生成）
```

## 数据来源

`data/docs.json` 根据 [《Chez Scheme 第 10 版用户指南》](https://cisco.github.io/ChezScheme/csug/)（Apache License 2.0，© Cisco Systems, Inc.）和 [《算法语言 Scheme 修订第 6 版报告》](https://www.r6rs.org/)（“我们允许免费复制其全部或部分内容”）生成。
