# 第三方许可声明

LinkNest 使用下列开源组件。直接依赖的精确版本以 `host_app/pubspec.lock` 和 `web/package-lock.json` 为准；传递依赖由对应包管理器按锁文件取得，其许可证随上游软件包提供。本声明不改变任何第三方组件的原始许可。

## 1. Flutter、Dart 与 Android 组件

| 组件 | 当前锁定版本 | 许可证 | 上游 |
| --- | --- | --- | --- |
| Flutter / flutter_localizations | 3.47.2 环境 | BSD-3-Clause | https://github.com/flutter/flutter |
| crypto | 3.0.7 | BSD-3-Clause | https://pub.dev/packages/crypto |
| path_provider | 2.1.6 | BSD-3-Clause | https://pub.dev/packages/path_provider |
| qr_flutter | 4.1.0 | BSD-3-Clause | https://pub.dev/packages/qr_flutter |
| shared_preferences | 2.5.5 | BSD-3-Clause | https://pub.dev/packages/shared_preferences |
| mime | 2.1.0 | BSD-3-Clause | https://pub.dev/packages/mime |
| http | 1.6.0 | BSD-3-Clause | https://pub.dev/packages/http |
| mobile_scanner | 7.4.2 | BSD-3-Clause | https://pub.dev/packages/mobile_scanner |
| video_player | 2.14.0 | BSD-3-Clause | https://pub.dev/packages/video_player |
| flutter_lints（开发） | 6.0.0 | BSD-3-Clause | https://pub.dev/packages/flutter_lints |
| nsd | 5.0.1 | MIT | https://pub.dev/packages/nsd |
| photo_view | 0.15.0 | MIT | https://pub.dev/packages/photo_view |
| forui | 0.27.2 | MIT | https://pub.dev/packages/forui |
| cupertino_icons | 1.0.9 | MIT | https://pub.dev/packages/cupertino_icons |
| flutter_launcher_icons（开发） | 0.14.4 | MIT | https://pub.dev/packages/flutter_launcher_icons |
| AndroidX ExifInterface | 1.4.2 | Apache-2.0 | https://developer.android.com/jetpack/androidx/releases/exifinterface |

BSD-3-Clause 组件的版权署名：

- Flutter、flutter_localizations、path_provider、shared_preferences、video_player、flutter_lints：Copyright 2013 The Flutter Authors。
- crypto：Copyright 2015 the Dart project authors。
- mime、http：Copyright 2014 the Dart project authors。
- qr_flutter：Copyright 2020 Luke Freeman。
- mobile_scanner：Copyright 2022 Julian Steenbakker。

BSD-3-Clause 许可原文：

```text
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

Apache-2.0 组件的许可全文见仓库根目录 `LICENSE`；相关组件的版权和 NOTICE 仍归各自上游项目所有。

## 2. Web 组件

| 组件 | 当前锁定版本 | 用途 | 许可证 |
| --- | --- | --- | --- |
| Vue | 3.5.42 | 运行时 | MIT |
| Swiper | 14.2.0 | 运行时 | MIT |
| Vite | 8.3.6 | 构建 | MIT |
| @vitejs/plugin-vue | 6.0.8 | 构建 | MIT |
| Tailwind CSS | 4.3.3 | 构建 | MIT |
| @tailwindcss/vite | 4.3.3 | 构建 | MIT |
| Lightning CSS | 锁文件所列版本 | 构建依赖 | MPL-2.0 |

MIT 组件的版权署名：

- nsd：Copyright 2021 Sebastian Haberey and others。
- photo_view：Copyright 2024 Renan C. Araújo。
- forui：Copyright 2026 Duobase IO。
- cupertino_icons：Copyright 2016 Vladimir Kharlampidi。
- flutter_launcher_icons：Copyright 2019 Mark O'Sullivan。
- Vue：Copyright 2018-present Yuxi (Evan) You。
- Swiper：Copyright 2019 Vladimir Kharlampidi。
- Vite：Copyright 2019-present VoidZero Inc. and Vite contributors。
- @vitejs/plugin-vue：Copyright 2019-present Yuxi (Evan) You and Vite contributors。
- Tailwind CSS、@tailwindcss/vite：Copyright Tailwind Labs, Inc.

MIT 许可原文：

```text
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

Lightning CSS 使用 Mozilla Public License 2.0，上游为 https://github.com/parcel-bundler/lightningcss ，许可全文见 https://mozilla.org/MPL/2.0/ 。本仓库不内嵌其源码或二进制；npm 在构建时按锁文件下载。重新分发该组件本身时，应同时遵守其文件级源码提供和许可保留要求。

## 3. 字体

- Lora：SIL Open Font License 1.1，完整原文保留在 `host_app/assets/fonts/Lora-OFL.txt`。
- Raleway：SIL Open Font License 1.1，完整原文保留在 `host_app/assets/fonts/Raleway-OFL.txt`。

字体的版权、保留字体名称和许可条件以对应 OFL 文件为准。应用通过 Flutter `LicenseRegistry` 登记这两份字体许可。

## 4. 发布时保留声明

发布 APK、Web 构建产物或衍生版本时，应在随附文档、Release 说明或许可页面中提供本声明及适用的第三方许可原文。修改或许可证升级后，应重新核对锁文件和上游许可，不能仅更新版本表。
