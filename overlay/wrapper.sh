#!@shell@
. @utils@
exename=@exename@
exepath="@rustc@/bin/$exename"
isBuildScript=
outputName=
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" = metadata=* ]]; then
    args[$i]="metadata=$NIX_RUST_METADATA"
  elif [ "${args[$i]}" = "--crate-name" ]; then
    if [[ "${args[$i+1]}" = build_script_* ]]; then
      isBuildScript=1
    elif [ -n "$selfLib" -a "${args[$i+1]}" = "$crateName" ]; then
      echo >&2 "skipping library rebuild"
      exit 0
    else
      outputName="${args[$i+1]}"
    fi
  elif [[ -n "$selfLib" && "${args[$i]}" = "--extern" && "${args[$i+1]}" = "$crateName="* ]]; then
    args[$(expr $i + 1)]="$crateName=$selfLib/lib$crateName.rlib"
  fi
done
if [ "$isBuildScript" ]; then
  args+=($NIX_RUST_BUILD_LINK_FLAGS)
else
  args+=($NIX_RUST_LINK_FLAGS)
fi
if [ "$exename" = rustc ]; then
  # not supported by rustdoc, which is called to run doctests
  args+=("--remap-path-prefix" "$NIX_BUILD_TOP=/source")

  if echo "$NIX_RUSTC_LINKER_HACK" | grep -q "\\b$outputName\\b"; then
    args+=("-Ctarget-feature=-crt-static" "-lstatic=stdc++")
  fi
fi
touch invoke.log
echo "$exepath ${args[@]}" >>invoke.log
exec "$exepath" "${args[@]}"
