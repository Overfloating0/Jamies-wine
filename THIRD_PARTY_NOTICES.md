# 第三方来源与许可证

Jamie's Wine 的源码及单文件运行脚本采用 **GNU Affero General Public License version 3 only（AGPL-3.0-only）**，完整条款见 [LICENSE](LICENSE)。对应源码位于 `src/`，构建脚本位于 `scripts/build.cjs`。

## Endfield-Poser

- 项目：[honxi1/Endfield-Poser](https://github.com/honxi1/Endfield-Poser)
- 来源提交：`2b9e6a2a1cf9c4a78063352dbcf0c955bba685e5`
- 参考文件：`src/math/jelly_party.h`、`src/game/jelly_party.h`、`tests/test_jelly_party.cpp`
- 许可证：[AGPL-3.0](https://github.com/honxi1/Endfield-Poser/blob/2b9e6a2a1cf9c4a78063352dbcf0c955bba685e5/LICENSE)

果冻波形移植为 Lua，保留固定周期与周期边界，扩展强度至 0—1，并加入 BPM、拍数、偏移、对齐、自定义体型组合与实时相位计算。SF6 的角色接入、目标管理、恢复和控制面板由本项目实现。

## MMDK

- 项目：[alphazolam/MMDK](https://github.com/alphazolam/MMDK)
- 来源提交：`831564f1993926a9fff834108f24767748d40c06`
- Copyright (c) 2023 alphaZomega
- 许可证：[MIT License](licenses/MMDK-MIT.txt)

用于研究玩家槽位、骨架更新路径及桑吉尔夫动作对应关系。参考资料包括 `Zangief Names.json`、`Zangief moves_dict.json` 和 `tables.lua`。本 Mod 运行时不依赖 MMDK。

## Noto Sans SC

- 项目：[Google Fonts / Noto Sans SC](https://github.com/google/fonts/tree/main/ofl/notosanssc)
- Copyright 2014-2021 Adobe (http://www.adobe.com/)
- 许可证：[SIL Open Font License 1.1](licenses/NotoSansSC-OFL.txt)
- 字体为未经修改的 `NotoSansSC[wght].ttf`，随包命名为 `NotoSansSC.ttf`。
- SHA-256：`a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`

## REFramework

[REFramework](https://github.com/praydog/REFramework) 是外部运行依赖，本目录不分发其二进制或源码。
