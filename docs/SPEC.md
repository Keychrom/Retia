# Retia 仕様書 v1.0（凍結）

Zig + wlroots 製タイル型 Wayland コンポジタ。タスクバー・スタートメニューを同梱したリッチ路線。

> **タグの約束**
> - 【決定】合意済み。変更には明示的な合意が必要
> - 【推奨】ドラフト側の提案。レビューで確定させる
> - 【未決】要議論。凍結前に潰す
>
> v1.0（最初の公開リリース）到達まで本書は生きている文書。変更はセクション末尾の履歴に追記する。

---

## 1. 目的と差別化軸

**目的**: 「compositor だけ提供して後はユーザーに任せる」(river) でも「WM ロジックごとユーザーに書かせる」(ShojiWM) でもない、**統合シェルを備えたリッチなタイル WM** を Zig で作る。

### 1.1 ポジショニング: 「niri 互換 × 統合シェル」— 焼き直し回避の 3 層モデル 【決定】

niri に寄せすぎると焼き直しになるため、**何を互換にし、何で差別化するかを 3 層で明示する**:

- **第 1 層: 操作文法は niri 互換（土台）** — Scrollable Columns、consume/expel、デフォルトキーバインド、KDL 設定、ジェスチャ。ユーザーの筋肉記憶をそのまま引き継ぐ。ここで独自路線を捏造しない
- **第 2 層: プロダクトは niri に無いもの（主差別化）** — niri は哲学としてバー/ランチャーを持たない。統合シェル（タスクバー + スタートメニュー）を備えた「niri 式タイリングの DE」は生きている隙間。COSMIC はフル DE だがタイリングも文法も別物なので隣に並ばない
- **第 3 層: 独自の看板機能（§4.5 / §8）** — ストリップ・ミニマップ、レイアウトのセッション永続化。スクロール型レイアウト固有の課題（「ストリップのどこにいるのか分からなくなる」）を統合シェルだからこそ解ける、という発想で選ぶ

比較: ShojiWM = WM ロジックを設定化 / river = 極小 / niri = 洗練された単機能 / 本プロジェクト = **niri 式タイリング + 統合シェル + Zig**。

### 1.2 差別化軸（既存 WM との重なりを避ける基準）

1. **言語**: リッチ路線では唯一の Zig 製（Hyprland=C++, ShojiWM/COSMIC/niri=Rust+Smithay, sway=C）
2. **統合シェル**: タスクバーとスタートメニューを同梱・同一リポジトリで一貫デザイン。ただし**プロセス分離**は保つ（シェルのクラッシュがコンポジタを落とさない）
3. **設定 = KDL 第一面 + Zig プラグイン拡張**: 誰でもいじれる宣言的 KDL（niri 互換文法）を第一面にし、上級者向けスクリプティングは Zig プラグイン（実験的）に分離。ShojiWM（TS が中心）とも niri（スクリプト不可）とも違うハイブリッド
4. **レイアウト**: 看板は Scrollable Columns（操作文法は niri 互換）。レイアウトは差し替え可能モジュールとし、将来的に独自レイアウトを追加する土台
5. **ターミナルとの連携**: kitty keyboard protocol 等の現行プロトコルを最優先で対応し、自作ターミナル（フェーズ 2）で緊密統合

## 2. 技術スタック 【決定】

| 項目 | 選択 | 備考 |
|---|---|---|
| 言語 | Zig（0.16.x をピン留め、破壊的変更は計画的に追従） | 1.0 未満であることをリスクとして受容（§13） |
| コンポジタ基盤 | wlroots（最新安定。M0 でバージョンをピン留め） | DRM/KMS・libinput・xwayland・レイヤーシェル等の下回りを担う |
| Wayland バインディング | [zig-wayland](https://codeberg.org/ifreund/zig-wayland) | river と同じ ifreund 製。クライアント側（シェル）とカスタムプロトコルで使用 |
| wlroots バインディング | **自前**（river と同様に手書き + translate-c 活用） | 既存の公開バインディングは停滞気味のため依存しない。M1 の主作業 |
| 描画 | wlroots レンダラ（GLES2）から開始 → 必要になったら自前レンダパス | アニメーション/シェーダの要求で切り替え判断（§13 リスク 4） |
| テキスト描画 | freetype + harfbuzz（C リンク） | 自前シェル UI 用 |
| 設定 | Zig ソースをコンパイル → dlopen（§6） | |
| ターミナル（初期） | Kitty | ユーザー環境に無ければ起動時フォールバック |

## 3. コンポジタコア

### 3.1 対応プロトコルマトリクス 【推奨】

**Must（v1.0 の出荷条件）**

| プロトコル | 用途 |
|---|---|
| core（wl_compositor, wl_seat, wl_output, wl_shm, wl_subsurface…） | 基礎 |
| xdg-shell | 通常ウィンドウ |
| xdg-decoration | サーバ/クライアントサイド装飾の折り合い |
| wlr-layer-shell | バー・ランチャー・壁紙・通知の配置 |
| xdg-output | 出力メタデータ |
| linux-dmabuf (v4) + viewporter + fractional-scale | ハードウェアアクセラレーション・HiDPI |
| wlr-foreign-toplevel-management | タスクバーのタスク一覧 |
| wlr-output-management + wlr-screencopy | ポータル経由の画面共有・スクショ |
| wlr-data-control | クリップボードマネージャ（cliphist 等） |
| pointer-constraints + relative-pointer | ゲーム・VM |
| tearing-control (wp) | 競技ゲーム向け即時描画 |
| cursor-shape (wp) | 新カーソル API |
| xdg-activation | フォーカス stolen 対策 |
| idle-notify (ext) + idle-inhibit + wlr-output-power-management | スリープ制御 |
| wlr-gamma-control | 夜間モード（外部ツール用） |
| presentation-time (wp) | 描画フィードバック |
| single-pixel-buffer (wp) | 軽量描画 |
| XWayland | X11 アプリ（wlroots 組み込み） |

**Should（v1.0 で頑張る）**: ext-session-lock（ロック画面）、wlr-virtual-pointer/keyboard（リモート操作）、ext-foreign-toplevel-list

**Could（余力）**: security-context（サンドボックス連携）、xdg-dialog / xdg-toplevel-tag / xdg-system-bell

**スクリーンキャスト方針**: wlr-screencopy + output-management を正しく実装し、xdg-desktop-portal(-wlr) を流用する（ポータル自作はしない）。

### 3.2 出力・マルチモニタ 【推奨】

- 出力ごとに独立した列ストリップ（§4）を持つ
- HiDPI: fractional-scale 対応、出力ごとの scale 設定
- ワークスペースは **niri 式（出力ごとに独立したワークスペース群、出力内で縦方向に切替）**【決定: niri 互換】

### 3.3 ライフサイクル・堅牢性 【推奨】

- クライアントが死んでもコンポジタは継続（wlroots 標準動作に従う）
- コンポジタの panic = 保存されないデータは無いという前提だが、設定不備で起動不能にならないよう、設定ロード失敗時はデフォルト設定 + エラー通知で起動する
- ログ: stderr + `XDG_RUNTIME_DIR` 下のファイル。`--verbose`

## 4. レイアウトエンジン: Scrollable Columns 【決定】

看板レイアウト。niri と同じ系統だが、仕様は独自に定義する（niri の挙動に合わせに行かない。差異は意図して付ける）。

### 4.1 データモデル

```text
Output
 └─ Workspace  (縦方向に切替。ワークスペースごとに独立)
     └─ Column[]   (横方向・スクロール。長さ制限なし)
         └─ Window[]  (縦に積む)
```

- Column は**幅**（px または比率）、Window は**列内での高さ比率**を持つ
- Viewport は x オフセットを持ち、**フォーカス列が常に見えている**ことを不変条件とする
- 列幅プリセット: 1/3, 1/2, 2/3, 全幅 + 相対増減【推奨】
- 列内の高さ: 均等割りがデフォルト、キー/ドラッグで比率変更【推奨】

### 4.2 操作一覧（初期セット） 【推奨】

- フォーカス: `focus-column-left/right`、`focus-window-up/down`（列内）
- 移動: `move-column-left/right`、`move-window-up/down`
- 組み替え: `consume-window-into-column`（隣列の窓を自分の列に取り込む）/ `expel-window-from-column`（放出）※この 2 操作がこのレイアウトの操作性の要
- 生成: `new-window` は**フォーカス列の隣に新しい列として開く**（niri 互換【決定】。niri は現行列への直接配置をデフォルトで持たず、consume/expel で組み替える方式が FAQ で確認済み）。列への縦積みは `consume-or-expel-window-left/right` で行う
- `toggle-column-tabbed-display`（列をタブ表示に切替）も niri 互換で対応【推奨】
- 幅: `set-column-width 1/3|1/2|2/3|+10%|-10%`、`expand-column-to-edge`
- 位置: `center-column`、`focus-column-first/last`
- 浮動/全画面: `toggle-window-floating`、`toggle-window-fullscreen`、`maximize-column`
- ワークスペース: `switch-workspace up/down/N`、`move-window-to-workspace`
- 浮動窓・ポップアップ・フルスクリーンはストリップの外側レイヤとして扱う

### 4.3 実装上の制約（アーキテクチャ） 【決定】

- レイアウトエンジンは**純粋モジュール**: `状態 + 操作 → 新状態 + (描画への) 変更通知`。wlroots 型に依存しない
- これにより `zig test` でヘッドレス検証ができ、仕様の状態遷移をそのままテストとして固定できる
- レイアウトはトレイト（Zig では vtable or comptime インターフェース）経由で差し替え可能にする。将来の Dwindle/独自レイアウト追加の受け皿

### 4.4 アニメーション 【決定・重要】

- スクロールアニメーションはこのレイアウトの生命線。**M2 の時点で easing を入れる**（M6 まで先送りしない）
- duration + 曲線プリセットを設定可能。アニメ種別ごとの off / slowdown も設定可能にする（niri の `animations` ノード互換の考え方）
- open/close はフェード+スケール（M6 で洗練）

### 4.5 セッション永続化（第 3 層・看板） 【決定・v1】

- レイアウト（列構造・幅・ワークスペース位置・ビューポート位置）をセッションまたぎで復元する。niri はポータル経由で「アプリの復元」は行うが列構造は復元しない
- スクロール型の「ストリップ = 作業空間」をドキュメントとして扱う発想。xdg session management と自前の状態ファイルの併用で実装
- 復元対象の窓は app-id + タイトルでマッチし、見つからなければプレースホルダ扱いにするか諦めるかは実装時に決定

## 5. 入力 【推奨】

- キーマップ: xkbcommon。レイアウト切替・Caps→Ctrl 等のオプションを設定から
- キーバインド: `(mods, keysym) → アクション` の表。モード（リーダーキー風の一時モード）を v1 で対応
- **デフォルトキーマップは niri のデフォルト設定を踏襲**【決定: niri 互換】: Mod+T 端末 / Mod+D ランチャー / Mod+Q 閉じる / Mod+H,J,K,L・矢印でフォーカス / Mod+Ctrl+H,J,K,L 移動 / Mod+Shift+H,J,K,L 出力間フォーカス / Mod+U,I ワークスペース / Mod+1..9 / Mod+[ , ] consume-or-expel / Mod+, . consume・expel / Mod+R プリセット幅 / Mod+F 最大化・Mod+Shift+F フルスクリーン / Mod+V 浮動切替 / Mod+O オーバービュー / Mod+Shift+/ ホットキーオーバーレイ
- ホットキーオーバーレイ（一覧ポップアップ）は設定から自動生成し、**自前シェルで描画**して一貫デザインにする（第 2 層差別化の小粒）
- マウス: `mod+左ドラッグ` で浮動化して移動、`mod+右ドラッグ` でリサイズ（他 WM と同じ慣習）
- タッチパッド: タップ=クリック、ナチュラルスクロール設定。ジェスチャは niri 準拠で **v1 は 3 本指横=ストリップスクロール、3 本指縦=ワークスペース切替に絞る**【決定】。押し込み等の拡張は v1.x
- キーリピート・遅延は設定可能

## 6. 設定システム 【決定】

**方式: KDL を第一面、Zig プラグインを拡張レイヤに。**

理由: Zig はまだマイナーで、設定まで Zig を要求すると誰もいじれない。第一面は誰でも編集できる宣言的 KDL とし、文法は niri 設定を踏襲して学習コストをゼロにする。

### 6.1 KDL 設定（第一面・niri 互換文法） 【決定】

- `~/.config/retia/config.kdl`、ホットリロード対応
- niri と同じノード構造を基本にする: `binds { }`、`layout { gaps / center-focused-column / preset-column-widths / default-column-width / focus-ring / border / shadow / struts }`、`animations { }`、`window-rule { match app-id=… title=… → open-floating / default-column-width / block-out-from … }`、`gestures`、`hotkey-overlay`、`input`【推奨】
- バリデーションエラーは**現行設定を維持したまま**、バーのトーストと `retiactl config errors` で通知（niri の挙動に準拠）
- niri からの移行: 設定ファイルをほぼそのまま持ってこられることを目標にする。差分ノードはバー連携など独自機能のみ【推奨】

### 6.2 Zig プラグイン拡張（第二面・実験的） 【推奨・v1.x】

- KDL では書けない動的挙動（独自レイアウトルール、外部イベント連携）だけを、コンパイル済み Zig プラグイン（dlopen、C-ABI）で差し込む
- **必須ではない**。標準ユーザーは KDL だけで完結する。ShojiWM（TS が中心）とも niri（スクリプト不可）とも違う中間点
- M4 では KDL のみ実装。プラグイン ABI は v1.x で実験的に設計する

## 7. IPC 【推奨】

- ソケット: `$XDG_RUNTIME_DIR/retia-*.sock`（コマンド用 + イベント用の 2 本）
- プロトコル: 行ベースのテキスト（sway 流）。`get` / `set` / `dispatch`。JSON は後から
- イベント: 区切りテキストのストリーム（`workspace>>2` 等）。タスクバーと CLI が購読
- CLI: `retiactl`【決定・プロジェクト名 Retia に連動】 — `retiactl dispatch focus-column-right` 等

## 8. 同梱シェル

シェルは**別プロセスの layer-shell クライアント**として実装する【決定】。UI は自前の軽量レンダラ（普通の Wayland クライアントとして OpenGL + freetype/harfbuzz）で、バーとスタートメニューで共有する【決定。dvui 不採用の理由は §8.1】。

### 8.1 タスクバー 【推奨】

| 機能 | v1 | 実装元 |
|---|---|---|
| スタートボタン | ○ | 自前 |
| ワークスペース一覧 | ○ | コア連携プロトコル（§8.3） |
| タスク一覧（クリックでフォーカス/切替） | ○ | wlr-foreign-toplevel-management |
| 時計カレンダー | ○ | 自前 |
| バッテリー・音量インジケータ | ○（表示のみ） | /sys, 外部ツール連携は後 |
| ストリップ・ミニマップ（全ワークスペースの列構造を縮小表示、クリックでジャンプ）【第 3 層・看板】 | ○（v1） | コア連携プロトコル（§8.3）+ レイアウト状態の push |
| システムトレイ (SNI/DBus) | v1.x | sd-bus を C リンク |
| 設定エラー等の通知表示 | ○ | IPC 購読 |

**バーのカスタマイズモデル【決定】: KDL で 9 割、Zig プラグインで残り 1 割（§6 の二面構成をシェルに転用）**

「かなりいじれる」を両層で担保する:

- **第一面: KDL でウィジェット構成（誰でも編集できる層）** — バーを `left / center / right` ゾーンのウィジェット列として宣言する。内蔵ウィジェット: start-button / workspaces / minimap / tasks / clock / battery / custom。ウィジェットごとに `style { background / padding / corner-radius / font / color }`、全体に `theme { パレット変数 }`。ウィジェットの `on-click` にアクション割り当て可。`custom` ウィジェットはシェルコマンドの出力を定周期・IPC イベントで表示（waybar の custom module 相当）なので、スクリプトを書ける人なら誰でも独自ウィジェットを追加できる
- **第二面: Zig プラグインウィジェット（完全自作の層・v1.x 実験）** — §6.2 と同じ思想の dlopen プラグインでバーに差し込む。ABI は小さく保つ: 即値モードのドローリスト生成（矩形/テキスト/アイコン/クリック領域の宣言）+ 更新トリガ（interval / IPC イベント購読）。バーはそれを描画するだけ。直接 OpenGL を触らせないのは意図的な制約で、ABI を安定・安全に保つため。もっと深くやりたければバー自体が同一リポジトリのモジュールなので PR/フォークで対応
- **隔離**: バーは別プロセスなのでプラグインがクラッシュしてもバーの再起動で済み、コンポジタは無傷【決定】
- **dvui 不採用の理由**: プラグイン ABI の設計自由度、Wayland バックエンドの成熟度リスク、統合デザイン（第 2 層差別化）を完全に制御したいこと。バーは単純 UI なので自前レンダラで十分に小さい

### 8.2 スタートメニュー 【推奨】

- XDG desktop entries のスキャン（`/usr/share/applications`, `~/.local/share/applications`）
- キーボードファースト: 開いた瞬間から検索ボックスにフォーカス、部分一致→あいまい検索（name/exec/keywords）
- 検索は「起動」と「窓切替」の統合: 実行中の窓が一致すればそこへアニメ付きでジャンプ、無ければ起動。fuzzel 相当の体験をスタートメニューに内蔵【第 3 層・看板・決定 v1】
- ピン留め、使用頻度順ソート
- カテゴリ別グリッドは v1.x
- アイコン: freedesktop icon theme の解決【決定】v1 は hicolor + ユーザー指定テーマ 1 本（1 段の継承）の簡易解決。テーマ継承の完全追従は v1.x

### 8.3 コア連携プロトコル 【推奨】

- `retia-private` Wayland プロトコル（wlroots の wayland-scanner で定義）をコア ↔ バー間に定義
- ワークスペース状態、フォーカス列、設定エラー等を push。foreign-toplevel で足りない部分だけ私用プロトコルにする（一般公開はしない）
- バーが死んでもコンポジタは継続。バー再起動で状態を再 push

## 9. ターミナル 【決定: 二段構え】

**v1.0: Kitty をデフォルトとして同梱設定**（ユーザー判断済み）。設定から kitty keyboard protocol を有効化し、コンポジタ側も対応。

**フェーズ 2: 自作ターミナル**（独立リポジトリ or 同梱サブプロジェクト）

- 要件: VT100/xterm コア、truecolor、kitty keyboard protocol、OSC 8 ハイパーリンク、OSC 52 クリップボード、SGR マウス、リサイズ時のリフロー、スクロールバック（リングバッファ）
- VT パーサ: libvterm（C）をリンクして開始、置き換え可能な設計に
- 描画: GPU グリフアトラス（コンポジタと共通化できる部分は共通化）
- 枠線: 通常の Wayland クライアントとして作る（コンポジタ内蔵サーフェスにはしない）

## 10. エコシステム互換 【推奨】

- ポータル: xdg-desktop-portal(-wlr) を流用（§3.1）
- 通知: 外部（mako / dunst）をレイヤーシェルで表示
- クリップボード: wl-clipboard / cliphist が data-control で動くこと
- セッション: swayidle 相当の外部ツール + idle-notify
- 壁紙: swaybg が動くこと（同梱しない）
- ステータス: 自前バーがデフォルト。waybar は layer-shell 互換で併用可能にする（互換性のリトマス紙）

## 11. 非目標（v1.0） 【推奨】

- X11 スタンドアローン（nested X11 バックエンドでの開発用途は残す）
- niri との完全互換を契約にすること（第 1 層の操作文法は互換だが、互換は土台であって保証ではない。独自機能では分かりやすく逸脱する）
- 自前の通知デーモン・ロック画面・スクリーンキーボード（ext-session-lock で外部ツールを使う）
- ウィジェットシステム・シェル拡張 API（ShojiWM がやる領域。やらないのが差別化）
- 音量/輝度の管理（外部ツールとキーバインド接続のみ）
- アクセシビリティ API

## 12. マイルストーン

| # | 内容 | 完了条件 |
|---|---|---|
| M0 | 仕様凍結（本書 v1.0）+ リポジトリ初期化 + Linux VM 開発環境 + 依存のピン留め | 本書の【未決】が 0 個 |
| M1 | wlroots 自前バインディング整備、nested 起動、1 サーフェス描画 | nested で kitty/foot の窓が単色画面に出る |
| M2 | xdg-shell + Scrollable Columns（純粋モジュール→統合）+ スクロール easing + 基本キーバインド | 10 窓開いて列組替え・スクロールが滑らかに動く |
| M3 | DRM standalone セッション（libseat/logind、libinput、マルチ出力、HiDPI） | 実機 TTY から起動し kitty が動く |
| M4 | KDL 設定（niri 互換文法 + ホットリロード）+ IPC + CLI | 設定変更が即座に反映、`retiactl` で操作できる |
| M5 | タスクバー（ミニマップ込み）+ 検索統合スタートメニュー（layer-shell クライアント + 私用プロトコル） | メニュー検索で「起動」と「窓ジャンプ」の両方が動く、タスククリックでフォーカス、ミニマップで列ジャンプ |
| M6 | エフェクト洗練（open/close、シェーダ実験）+ セッション永続化（§4.5） | 見た目の完成度が「リッチ」の水準に達し、再起動で列構造が復元する |
| M7 | 自作ターミナル（kitty からの置き換え） | 日常使用に耐える（VT カバレッジ目標: 主要シェル/CLI ツールが破綻しない） |
| M8 | XWayland、ポータル、idle/gamma、仕上げ | v0.1 タグ。他の WM から乗り換えて 1 日使える状態 |

## 13. リスクと対策

1. **Zig の破壊的変更**（0.16→0.17…）→ バージョンをピン留めし、アップグレードは計画的なタスクとして扱う
2. **wlroots の API 変更** → M0 でピン留め。river の追従コミットを参考にする
3. **バインディングの自前整備が M1 の山** → river の手書きバインディングを参考に、必要分だけ段階的に
4. **アニメ/シェーダが wlroots 標準レンダラの限界に当たる** → scene graph で開始し、自前レンダパスへの移行を M6 の判断点とする
5. **NVIDIA** → wlroots の legacy GBM 経由でベストエフォート。動作保証はしないと明記
6. **作業量（一人想定）** → シェル・ターミナルをプロセス/モジュールで隔離し、どの時点でも「動く WM」として段階リリースする

## 14. 開発環境・テスト 【推奨】

- 開発は Linux（実機 or QEMU/KVM + virtio-gpu の VM）。Windows 側はエディタのみにする
- 日常の開発ループ: `WLR_BACKENDS=wayland` で既存デスクトップ上に nested 起動
- テスト: レイアウトエンジン = `zig test`（ヘッドレス、CI で回す）。プロトコル段階 = `WLR_BACKENDS=headless` + 仮想出力
- CI: Linux コンテナでビルド + zig test（描画はしない）
- 参考実装: river（Zig+wlroots の唯一の先人）、tinywl（最小構成）、niri（レイアウト UX の比較基準）

## 15. 残存事項（凍結の扱い）

プロダクトの意思決定はすべて確定した。以下は実装時に確定して本書へ反映する実装詳細:

- [ ] IPC のイベント一覧とペイロード詳細（§7・方式は行ベーステキストで確定済み。M4 実装時に確定）

---

## 履歴

- 2026-10-25: v0.1 ドラフト作成。技術スタック（Zig + wlroots）とレイアウト（Scrollable Columns）を決定。
- 2026-10-25: v0.2 更新。niri 互換ポリシー（3 層モデル）を明文化し焼き直し問題に対処。設定を「KDL 第一面 + Zig プラグイン拡張」に変更。ワークスペース・新規窓・デフォルトキーマップを niri 互換として決定。看板候補（ミニマップ、セッション永続化、検索統合スタートメニュー）を追加。
- 2026-10-25: v0.3 更新。第 3 層の看板機能 3 点（ミニマップ・セッション永続化・検索統合スタートメニュー）を **v1 スコープに確定**。M5（シェル）と M6（永続化）に反映。
- 2026-10-25: v0.4 更新（凍結候補）。プロジェクト名を **Retia** に決定（retiactl・config パス・ソケット名が連動確定）。バーのカスタマイズモデルを決定（KDL ウィジェット構成 + Zig プラグインウィジェットの二面構成、dvui 不採用）。アイコン解決・ジェスチャ範囲も決定し、未決は IPC 詳細（M4 実装時確定）のみ。
- 2026-10-25: **v1.0 凍結**。ドラフト期間の全決定事項を確定。以降の変更は履歴に理由を付して追記する（実装詳細の反映を除く）。
