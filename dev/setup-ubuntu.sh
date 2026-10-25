#!/usr/bin/env bash
# Retia 開発環境セットアップ (Ubuntu 24.04+, SPEC.md M0 の依存ピン留めを反映)
# 使い方: VM 内で `bash setup-ubuntu.sh`
set -euo pipefail

# ---- ピン留め (SPEC §2 / §13 を参照。変更時は SPEC 履歴にも記すこと) ----
# 0.19 ブランチ先端 = 0.19.0 タグ + libinput 1.28 / glibc 2.42 (C23) 対応済み
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
WLROOTS_REF="${WLROOTS_REF:-0.19}"
# ----------------------------------------------------------------------

echo "==> apt 依存のインストール"
sudo apt-get update
sudo apt-get install -y \
  build-essential git meson ninja-build pkg-config curl ca-certificates unzip \
  cmake \
  libwayland-dev wayland-protocols \
  libxkbcommon-dev libinput-dev libevdev-dev libdrm-dev libgbm-dev \
  libudev-dev libpixman-1-dev \
  libseat-dev libdisplay-info-dev hwdata \
  libegl-dev libgl-dev libgles-dev \
  libxcb1-dev libxcb-composite0-dev libxcb-render0-dev libxcb-shm0-dev \
  libxcb-xfixes0-dev libxcb-cursor-dev libxcb-icccm4-dev libxcb-image0-dev \
  libxcb-keysyms1-dev libxcb-randr0-dev libxcb-xinput-dev libxcb-xkb-dev \
  libxcb-res0-dev \
  xwayland \
  libfreetype-dev libharfbuzz-dev \
  kitty foot

# libliftoff は wlroots 0.19 で >=0.5.0 が必要。無い/古い場合はソースから入れる
liftoff_ok=0
if pkg-config --exists libliftoff; then
  if pkg-config --modversion libliftoff | awk -F. '{ exit !($1>0 || ($1==0 && $2>=5)) }'; then
    liftoff_ok=1
  fi
fi
if [ "$liftoff_ok" = 0 ]; then
  echo "==> libliftoff (>=0.5.0) をソースからビルド"
  mkdir -p ~/src && cd ~/src
  [ -d libliftoff ] || git clone https://gitlab.freedesktop.org/emersion/libliftoff.git
  cd libliftoff
  meson setup build --wipe
  sudo ninja -C build install
  sudo ldconfig
fi

echo "==> Zig ${ZIG_VERSION} の導入"
if ! command -v zig >/dev/null 2>&1; then
  mkdir -p ~/.local/opt ~/.local/bin
  cd ~/.local/opt
  # 0.15 以降は zig-x86_64-linux、それ以前の命名は zig-linux-x86_64
  ZIG_DIR=""
  for name in "zig-x86_64-linux-${ZIG_VERSION}" "zig-linux-x86_64-${ZIG_VERSION}"; do
    if curl -fLO "https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz"; then
      ZIG_DIR="${name}"
      break
    fi
  done
  [ -n "${ZIG_DIR}" ] || { echo "zig ${ZIG_VERSION} のダウンロードに失敗。URL 命名を確認して ZIG_VERSION を調整してください" >&2; exit 1; }
  tar -xf "${ZIG_DIR}.tar.xz"
  ln -sf "${HOME}/.local/opt/${ZIG_DIR}/zig" ~/.local/bin/zig
fi
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc; export PATH="$HOME/.local/bin:$PATH" ;;
esac
zig version

echo "==> wlroots ${WLROOTS_REF} をソースからビルド"
mkdir -p ~/src && cd ~/src
[ -d wlroots ] || git clone https://gitlab.freedesktop.org/wlroots/wlroots.git
cd wlroots
git fetch origin --force
git checkout "${WLROOTS_REF}"

# --- 0.19.0 タグを直接ビルドする場合用のパッチ (0.19 ブランチでは適用済みなので無視される) ---
# libinput >=1.28 の LIBINPUT_SWITCH_KEYPAD_SLIDE 未処理で -Werror が落ちる
grep -q "default: break;" backend/libinput/switch.c || sed -i '/switch (libinput_event_switch_get_switch(sevent)) {/a\
        default: break;
' backend/libinput/switch.c
# glibc 2.42 (C23) は strchr を const 正しく返すため char * への代入が -Werror で落ちる
grep -q "(char \*)strchr(path" xcursor/xcursor.c || sed -i "s/char \*colon = strchr(path, ':');/char *colon = (char \*)strchr(path, ':');/" xcursor/xcursor.c

# build ディレクトリはユーザー所有で作り直す (root でビルドすると .ninja_log が root 所有になり
# 以後のユーザービルドが Permission denied で死ぬ)。examples は -Werror の表面積を増やすだけなので切る
sudo rm -rf build
meson setup build -Dexamples=false
ninja -C build
sudo ninja -C build install
sudo ldconfig

# /usr/local の multiarch pkgconfig がデフォルト検索に無い環境 (新しい Ubuntu の pkgconf 等) 向け。
# M1 以降の zig build が pkg-config 経由で wlroots を探すため恒久設定にする
pcdir="/usr/local/lib/$(gcc -dumpmachine)/pkgconfig"
if [ -d "$pcdir" ] && ! grep -q "$pcdir" ~/.bashrc; then
  echo "export PKG_CONFIG_PATH=\"$pcdir:\$PKG_CONFIG_PATH\"" >> ~/.bashrc
  export PKG_CONFIG_PATH="$pcdir:$PKG_CONFIG_PATH"
fi

echo
echo "==> 完了。確認: zig version / pkg-config --modversion wlroots-0.19  (パッケージ名は wlroots ではなく wlroots-0.19)"
echo "    次は DEVENV.md の開発ループ (WLR_BACKENDS=wayland で nested 起動) に進む。"
