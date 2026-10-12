# サードパーティ / 上流コンポーネントのライセンス

本リポジトリの **LICENSE（MIT）が適用されるのはこのリポジトリのオリジナル部分のみ**
（`rtl/` の自作 HDL、ビルドスクリプト、ドキュメント。各ファイルの SPDX ヘッダが正）。

ビルドされるファームウェアイメージ（pluto.frm）は以下の上流コンポーネントを含み、
それぞれのライセンスに従う。対応ソースは本リポジトリのタグ（submodule のピン +
フォーク上の差分）から再現できる。

| コンポーネント | 由来 | ライセンス | 備考 |
|---|---|---|---|
| plutosdr-fw（ビルドシステム） | analogdevicesinc/plutosdr-fw のフォーク | 上流に従う（各 submodule の集合） | タグ v0.39 起点 |
| HDL リファレンスデザイン（axi_ad9361, util_cpack2, axi_dmac 等） | analogdevicesinc/hdl のフォーク | ADI デュアル（BSD 系 / GPL-2.0） | フォーク内の改変もこのデュアルに従う |
| Linux カーネル（ADI ブランチ） | analogdevicesinc/linux のフォーク | GPL-2.0 | **本プロジェクトのカーネルパッチ（scan_type 変更等）も GPL-2.0** |
| U-Boot | u-boot-xlnx | GPL-2.0+ | 無改変 |
| Buildroot とユーザランド（libiio, iiod ほか） | analogdevicesinc/buildroot | 各パッケージのライセンス（buildroot `make legal-info` で一覧化） | libiio は LGPL-2.1+ |

- 本リポジトリは Analog Devices, Inc. とは無関係の非公式プロジェクト。
- 「PlutoSDR」「ADALM-PLUTO」は Analog Devices の製品名であり、本プロジェクトは互換クローン機での利用を想定した改造ファームウェアである。
