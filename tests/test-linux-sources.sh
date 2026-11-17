#!/usr/bin/env bash
# No downloads or real Buildroot builds: exercise lookup and legacy migration.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_DIR/uclinux_common.sh"
test_root="$(mktemp -d /tmp/uclinux-linux-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT
WORK_ROOT="$test_root/work space"
uclinux_resolve_paths
TIMESTAMP=test
mkdir -p "$STM32_OUT/build" "$QEMU_OUT/build" "$LOG_DIR"

expect_status() {
    local expected=$1 actual
    shift
    if "$@" >"$test_root/stdout" 2>"$test_root/stderr"; then
        actual=0
    else
        actual=$?
    fi
    [[ "$actual" == "$expected" ]] || {
        printf 'FAIL: expected %s, got %s: %s\n' "$expected" "$actual" "$*" >&2
        cat "$test_root/stderr" >&2
        exit 1
    }
}

fake_kernel() {
    mkdir -p "$1/arch" "$1/drivers"
    touch "$1/Makefile" "$1/Kconfig"
}

# A headers tree has kernel files too: it must be explicitly excluded.
make() { printf 'lookup invoked make\n' >&2; return 99; }
printf 'external state must stay unchanged\n' >"$STM32_OUT/.br2-external.mk"
expect_status 1 uclinux_linux_build_dir "$STM32_OUT"
fake_kernel "$STM32_OUT/build/linux-headers-6.1.133"
expect_status 1 uclinux_linux_build_dir "$STM32_OUT"
mkdir -p "$STM32_OUT/build/linux-incomplete"
touch "$STM32_OUT/build/linux-incomplete/Makefile"
fake_kernel "$STM32_OUT/build/linux-6.1.133"
expect_status 0 uclinux_linux_build_dir "$STM32_OUT"
[[ "$(<"$test_root/stdout")" == "$STM32_OUT/build/linux-6.1.133" ]]
fake_kernel "$STM32_OUT/build/linux-custom"
expect_status 2 uclinux_linux_build_dir "$STM32_OUT"
grep -q 'ambigus' "$test_root/stderr"
grep -qx 'external state must stay unchanged' "$STM32_OUT/.br2-external.mk"
unset -f make
printf 'PASS: empty, headers, incomplete, unique, ambiguous, non-mutating lookup\n'

# Mock package work, but exercise the real preparation/reset function.
branch="$(git -C "$SCRIPT_DIR" symbolic-ref --quiet --short HEAD \
    || git -C "$SCRIPT_DIR" rev-parse HEAD)"
uclinux_require_buildroot() { :; }
info() { :; }
warn() { :; }
ok() { :; }
die() { printf '%s\n' "$*" >&2; exit 61; }
run_with_log() { shift; "$@" || die 'mock package failure'; }
uclinux_generate_stm32_config() {
    printf 'generate-stm32\n' >>"$test_root/calls"
    printf 'BR2_LINUX_KERNEL_VERSION="6.1.133"\n' >"$STM32_OUT/.config"
}
uclinux_generate_qemu_config() {
    printf 'generate-qemu\n' >>"$test_root/calls"
    printf 'BR2_LINUX_KERNEL_VERSION="6.12.27"\n' >"$QEMU_OUT/.config"
}
make_br() {
    shift
    printf 'make %s\n' "$*" >>"$test_root/calls"
}
printf 'configured\n' >"$STM32_OUT/.config"
printf '%s\n' "$branch" >"$STM32_OUT/.helpers-branch"
touch "$test_root/calls"
uclinux_prepare_buildroot stm32
[[ ! -s "$test_root/calls" ]]

mkdir -p "$WORK_ROOT/linux-6.1.133" "$STM32_OUT/target" \
    "$STM32_OUT/build/host-tool" "$STM32_OUT/build/target-tool"
touch "$WORK_ROOT/linux-6.1.133/student-change.c" \
    "$STM32_OUT/target/stale" \
    "$STM32_OUT/build/host-tool/.stamp_configured" \
    "$STM32_OUT/build/target-tool/.stamp_configured"
printf 'OTHER_OVERRIDE_SRCDIR = /keep\nLINUX_OVERRIDE_SRCDIR = %s/linux-6.1.133\n' \
    "$WORK_ROOT" >"$STM32_OUT/local.mk"
uclinux_prepare_buildroot stm32
grep -qx 'OTHER_OVERRIDE_SRCDIR = /keep' "$STM32_OUT/local.mk"
! grep -q '^LINUX_OVERRIDE_SRCDIR' "$STM32_OUT/local.mk"
[[ -f "$WORK_ROOT/linux-6.1.133/student-change.c" ]]
[[ ! -e "$STM32_OUT/build/linux-custom" && ! -e "$STM32_OUT/target" ]]
[[ -f "$STM32_OUT/build/host-tool/.stamp_configured" ]]
[[ ! -f "$STM32_OUT/build/target-tool/.stamp_configured" ]]
[[ "$(<"$STM32_OUT/.helpers-branch")" == "$branch" ]]
cp "$test_root/calls" "$test_root/first-calls"
uclinux_prepare_buildroot stm32
cmp "$test_root/calls" "$test_root/first-calls"
printf 'PASS: same-branch migration, clone/settings preserved, reset only once\n'

# Missing .config is normal after a manual reset; interruption must be resumable.
printf 'LINUX_OVERRIDE_SRCDIR = %s/linux-6.12.27\n' "$WORK_ROOT" >"$QEMU_OUT/local.mk"
printf '%s\n' "$branch" >"$QEMU_OUT/.helpers-branch"
sed() {
    if [[ "$1" == -i && ${MOCK_EDIT_FAIL:-0} == 1 ]]; then return 33; fi
    command sed "$@"
}
MOCK_EDIT_FAIL=1
prepare_qemu() ( uclinux_prepare_buildroot qemu; )
expect_status 61 prepare_qemu
grep -q '^LINUX_OVERRIDE_SRCDIR = ' "$QEMU_OUT/local.mk"
[[ ! -e "$QEMU_OUT/.helpers-branch" ]]
MOCK_EDIT_FAIL=0
uclinux_prepare_buildroot qemu
[[ -f "$QEMU_OUT/.config" ]]
! grep -q '^LINUX_OVERRIDE_SRCDIR' "$QEMU_OUT/local.mk"
printf 'PASS: missing configuration, interrupted cleanup, successful retry\n'

for override in \
    'LINUX_OVERRIDE_SRCDIR = /someone/elses/kernel' \
    'LINUX_OVERRIDE_SRCDIR := /another/kernel' \
    "LINUX_OVERRIDE_SRCDIR = $WORK_ROOT/linux-6.1.133/modified"; do
    printf '%s\n' "$override" >"$QEMU_OUT/local.mk"
    cp "$QEMU_OUT/local.mk" "$test_root/unknown.mk"
    cp "$test_root/calls" "$test_root/before-refusal"
    expect_status 61 prepare_qemu
    cmp "$QEMU_OUT/local.mk" "$test_root/unknown.mk"
    cmp "$test_root/calls" "$test_root/before-refusal"
    [[ "$(<"$QEMU_OUT/.helpers-branch")" == "$branch" ]]
done
mv "$QEMU_OUT/local.mk" "$test_root/symlink-target.mk"
printf 'LINUX_OVERRIDE_SRCDIR = %s/linux-6.12.27\n' "$WORK_ROOT" >"$test_root/symlink-target.mk"
cp "$test_root/symlink-target.mk" "$test_root/before-symlink.mk"
ln -s "$test_root/symlink-target.mk" "$QEMU_OUT/local.mk"
expect_status 61 prepare_qemu
cmp "$test_root/symlink-target.mk" "$test_root/before-symlink.mk"
printf 'PASS: unknown overrides and symlink refused without mutation\n'

# Framebuffer ROMFS branches inspect Linux before building. A clean output is
# normal; ambiguity must stop before any package operation.
if grep -q 'local linux_dir linux_config=""' "$SCRIPT_DIR/4_uclinux_stm32_dl_and_build.sh"; then
    source <(sed -n '/^uclinux_step_build_stm32()/,/^}/p' "$SCRIPT_DIR/4_uclinux_stm32_dl_and_build.sh")
    probe_romfs_build() (
        STM32_OUT=$1
        STATE_DIR="$test_root/state"
        UCLINUX_BR2_EXTERNAL_SET=0
        REBUILD_PACKAGES=()
        mkdir -p "$STATE_DIR"
        section() { :; }
        uclinux_prepare_buildroot() { :; }
        stm32_linux_inputs_fingerprint() { printf 'unchanged\n'; }
        make_br() {
            case "${2:-build}" in
                build) exit 70 ;;
                linux-reconfigure) exit 71 ;;
                *) exit 72 ;;
            esac
        }
        uclinux_step_build_stm32
    )
    expect_status 70 probe_romfs_build "$test_root/fresh-output"
    fake_kernel "$test_root/extracted/build/linux-6.1.133"
    expect_status 71 probe_romfs_build "$test_root/extracted"
    printf 'CONFIG_SPI_STM32=y\nCONFIG_FB_STM32F429_DISCO_SIMPLE=y\n' \
        >"$test_root/extracted/build/linux-6.1.133/.config"
    expect_status 70 probe_romfs_build "$test_root/extracted"
    fake_kernel "$test_root/extracted/build/linux-custom"
    expect_status 61 probe_romfs_build "$test_root/extracted"
    printf 'PASS: ROMFS first build, reconfiguration, incremental build, ambiguity\n'
fi
