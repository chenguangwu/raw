# raw

站点构建产物的存放仓库。仓库里只有拆分后的 zip，实际站点内容由部署插件发布。

- 线上站点：https://37kw0p1tts2uvdgscmy.traesite.cn（默认仅自己可见）
- 完整流程与硬性约束见 [AGENTS.md](AGENTS.md)

## 产物

| 文件 | 内容 |
|-|-|
| `github-pages-main.zip` | 除 `zh-tw` 外的全部站点文件（内含 `main.tar`） |
| `github-pages-zh-tw.zip` | 仅 `zh-tw` 目录（内含 `zhtw.tar`） |

原始 `github-pages.zip` 超过 GitHub 单文件 100 MB 限制，必须拆分后再提交；它只是输入素材，不进版本库。

## 使用

把新的站点 zip 放到仓库根目录后执行：

```bash
scripts/deploy-site.sh                    # 拆分 -> 提交推送 -> 部署
scripts/deploy-site.sh path/to/xxx.zip    # 指定输入 zip
scripts/deploy-site.sh --public           # 发布为所有人可见
scripts/deploy-site.sh --no-push          # 只拆分并本地提交
scripts/deploy-site.sh --no-deploy        # 只拆分并提交推送
```

可选环境变量：`SITE_NAME`、`SITE_ID`、`APP_TAGS`、`BRANCH`。

## 说明

- 两个 zip 都是「zip 套 tar」：单 tar 流压缩率更高，主包约 85 MB、`zh-tw` 包约 44 MB，均在 100 MB 限制内。
- 站点约 2.96 万个文件、515 MB，超出平台常规静态与函数模式的文件数上限，因此部署时会把内容合成单个 `data.bin` + `index.json`，由内置 Node 服务读取。
- 部署前会自动复用已有站点（按站点描述中的 `Source: GitHub repo chenguangwu/raw` 匹配），并检查是否已有进行中的部署。
