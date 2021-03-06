target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%floating = type { i64, { i64, i32, i64, i64 * } } ; exp, mpfr_t

; helper function for float hooks
define %floating* @move_float(%floating* %val) {
  %loaded = load %floating, %floating* %val
  %malloccall = tail call i8* @koreAllocOld(i64 ptrtoint (%floating* getelementptr (%floating, %floating* null, i32 1) to i64))
  %ptr = bitcast i8* %malloccall to %floating*
  store %floating %loaded, %floating* %ptr
  ret %floating* %ptr
}

declare noalias i8* @koreAllocOld(i64)

