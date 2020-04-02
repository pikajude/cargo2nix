#!@shell@
. @utils@
exename=@exename@
exepath="@rustc@/bin/$exename"
isBuildScript=
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" = metadata=* ]]; then
    args[$i]="metadata=$NIX_RUST_METADATA"
  elif [ "${args[$i]}" = "--crate-name" ] && [[ "${args[$i+1]}" = build_script_* ]]; then
    isBuildScript=1
  fi
done
if [ "$isBuildScript" ]; then
  # exename is always rustc, since rustdoc isn't run on build scripts
  args+=($NIX_RUSTC_BUILD_FLAGS $NIX_EXTRA_RUST_FLAGS $NIX_EXTRA_RUSTC_BUILD_FLAGS)
else
  args+=($NIX_RUSTC_FLAGS $NIX_EXTRA_RUST_FLAGS)
  if [ "$exename" = rustc ]; then
    args+=($NIX_EXTRA_RUSTC_FLAGS)
  fi
fi
debug_print "$exepath ${args[@]}"
exec "$exepath" "${args[@]}"
