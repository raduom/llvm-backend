file(GLOB files ${CMAKE_INSTALL_PREFIX}/lib/kllvm/rust/deps/*.rlib)
foreach(file ${files})
  execute_process(COMMAND ${CMAKE_INSTALL_PREFIX}/bin/llvm-kompile-rust-lto ${file})
endforeach()
execute_process(COMMAND ${CMAKE_INSTALL_PREFIX}/bin/llvm-kompile-rust-lto ${CMAKE_INSTALL_PREFIX}/lib/kllvm/rust/libdatastructures.rlib)
