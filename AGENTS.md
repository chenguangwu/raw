# AGENTS.md

本仓库用于存放站点构建产物（zip），并通过部署插件把内容发布为可访问站点。
所有自动化操作遵循本文件的约定。

## 1. 目标流程

输入：一个包含完整站点的 zip（`github-pages.zip`，可超过 100 MB）。

固定四步：

1. 拆分：把 `zh-tw` 目录从站点中拆出，生成两个 zip。
2. 提交：只提交这两个 zip，推送到 `origin/main`。
3. 合并：部署时把两个 zip 的内容重新合成一份站点。
4. 发布：用 deployment 插件创建部署并等待终态。

一键执行：

```bash
scripts/deploy-site.sh                      # 默认读取仓库根目录 github-pages.zip
scripts/deploy-site.sh path/to/xxx.zip      # 指定输入 zip
scripts/deploy-site.sh --public             # 站点设为所有人可见
scripts/deploy-site.sh --no-push            # 只拆包并本地提交，不推送
scripts/deploy-site.sh --no-deploy          # 只拆包 + 提交推送，不部署
```

可选环境变量：`SITE_NAME`、`SITE_ID`、`APP_TAGS`、`BRANCH`。

## 2. 产物约定

| 文件 | 内容 | 说明 |
|-|-|-|
| `github-pages-main.zip` | 除 `zh-tw` 外的全部站点文件 | 内含 `main.tar` |
| `github-pages-zh-tw.zip` | 仅 `zh-tw` 目录 | 内含 `zhtw.tar` |

- 两个包内部都是「zip 套一个 tar」。原因：直接对 2 万个文件做 deflate，主包会到 108 MB，仍超 GitHub 限制；把文件打成单个 tar 流再压缩，跨文件共享字典，主包约 85 MB、zh-tw 包约 44 MB。
- 每个 zip 必须小于 100 MB（GitHub 单文件硬限制）。脚本在写盘前会校验，超限直接失败。
- 原始 `github-pages.zip` 是输入素材，不进版本库；脚本不会 `git add` 它，必要时会把它从索引中移除。
- 打包时排除 `__pycache__`、`.DS_Store` 等非站点文件。

## 3. Git 约束

- 只向 `main` 提交，禁止 force push、禁止改写已推送历史。
- 提交信息格式：`chore: update split github-pages archives (YYYY-MM-DD HH:MM)`。
- GitHub 拒绝推送任何包含 ≥100 MB 文件的提交。若本地存在未推送的提交且其中含大文件，脚本会中止；处理方式是：

```bash
git reset --mixed origin/main   # 保留工作区文件，丢弃本地大文件提交
scripts/deploy-site.sh ...
```

- 只提交 `github-pages-main.zip`、`github-pages-zh-tw.zip`，不要顺手提交临时文件、日志、`.DS_Store`。

## 4. 部署约束

平台配额决定了两条常规路径都走不通：

| 模式 | 文件数上限 | 体积上限 |
|-|-|-|
| 常规静态（static-web） | 99 个文件 | 50 MiB（未压缩） |
| 函数（function-web） | 1000 个文件 | 单文件 1 GB |

本站点约 2.96 万个文件、约 515 MB，因此必须使用「单文件数据包 + Node 服务」方案：

- `data.bin`：所有站点文件按顺序拼接的原始字节。
- `index.json`：`路径 -> [偏移, 长度, 修改时间]` 的索引。
- `server.mjs`：读取索引，按偏移做随机读取，支持 GET/HEAD、ETag、Range。
- `build.sh` 把 `server.mjs/run.sh/package.json/index.json/data.bin` 复制到 `dist/`，`run.sh` 启动 Node。

必须遵守：

- 运行时 Node.js 20，零第三方依赖，不得包含 `node_modules`。
- 监听 `0.0.0.0`，端口取 `process.env.PORT`（执行配置固定 8000）。
- `run.sh` / `build.sh` 使用 `#!/bin/sh` 与 POSIX 语法，并保持可执行位。
- **Content-Type 必须按最终命中的文件路径推导**，不能按请求 URL 推导。否则 `/`、`/zh-tw/` 这类无扩展名路径会返回 `application/octet-stream`，浏览器变成下载文件（历史事故）。
- 路径解析顺序：精确命中 → `<path>/index.html` → `<path>.html`；拒绝 `..`、反斜杠、空字节。
- 所有临时目录必须建在系统临时目录（`mktemp -d`），不得放进仓库；脚本退出时清理。
- 站点描述中固定包含 `Source: GitHub repo <owner/repo>`，脚本据此识别并复用已有站点；不要改动这段文案，否则会重复建站。
- 默认可见性为「仅自己可见」；只有显式 `--public` 才设为所有人可见。
- 同一站点存在未结束的部署时，不得重复创建；脚本会检查并中止。

## 5. 部署完成后的动作

- 必须以部署服务的终态为准（`deployments wait` 返回 `wait_reason=terminal` 且 `status=9` 才算成功）。
- 成功后有部署卡片工具时，必须展示一次部署卡片，并报告站点名称、URL、部署 ID、可见性。
- 截图刷新失败不算部署失败，如实说明即可。
- 失败时先看对应阶段日志（build / deploy / runtime），只根据可操作的错误修改；不要盲目重试同样的源。

## 6. 排查清单

| 现象 | 原因 / 处理 |
|-|-|
| 打开站点变成下载文件 | Content-Type 取错，检查 `contentType()` 是否用了命中后的 key |
| `/zh-tw/` 404 | 缺少目录回退规则，或索引里没有 `/zh-tw/index.html` |
| 推送被拒 `exceeds GitHub's file size limit` | 提交历史里有 ≥100 MB 文件，先 `git reset --mixed origin/main` |
| `FUNCTION_FILE_LIMIT` | 上传的是散文件，应改为 `data.bin` + `index.json` 打包方案 |
| `STATIC_SIZE_LIMIT` / `STATIC_FILE_LIMIT` | 同上，改走打包方案 |
| 部署卡在构建 | 看 `logs build`，多半是 `build.sh` 未把运行文件复制进 `dist/` |
| 站点 307 `login_required` | 站点为「仅自己可见」，用 `--public` 重新部署即可公开 |
