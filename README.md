# 小象输入法 (XiaoXiang IME)

纯本地离线的 iOS 中文输入法：**全拼 + 小鹤双拼**，核心解码 / 自学习引擎为 100% 自研 C++17，经 Objective‑C++ 桥接给 Swift。

- `Core/` 音节切分与双模有向图、`mmap` 只读紧凑前缀树词库、空间概率 + 维特比束搜索、增量自学习用户词库
- `Tools/dictbuilder.cpp` 离线词库编译器（拉取 rime‑ice 雾凇拼音 → 严格清洗 → 带魔数 / 版本 / 校验和的 `.bin`）
- `Keyboard/` 键盘扩展（`com.custom.ime.keyboard`）：全画布裸触控状态机、纯数学帧布局
- `App/` 宿主应用（`com.custom.ime`）：打字测试沙盒与完整设置
- `.github/workflows/build.yml` 云端：词库 → XcodeGen → 无签名 Release `.ipa` → GitHub Release → 全能签软件源

软件源订阅地址：`https://<owner>.github.io/<repo>/apps.json`
