cmake_minimum_required (VERSION 3.4)

find_program(CMAKE_C_COMPILER clang-7)
find_program(CMAKE_C_COMPILER clang-6.0)
find_program(CMAKE_C_COMPILER clang)
find_program(CMAKE_CXX_COMPILER clang++-7)
find_program(CMAKE_CXX_COMPILER clang++-6.0)
find_program(CMAKE_CXX_COMPILER clang++)
project (KLLVM CXX C)

set(CMAKE_DISABLE_SOURCE_CHANGES ON)
set(CMAKE_DISABLE_IN_SOURCE_BUILD ON)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
add_definitions(-Wall -Werror)
set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -flto")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -flto")
set(CMAKE_EXE_LINKER_FLAGS_RELEASE "${CMAKE_EXE_LINKER_FLAGS_RELEASE} -flto")

set(CMAKE_AR "${CMAKE_C_COMPILER_AR}")
set(CMAKE_RANLIB "${CMAKE_C_COMPILER_RANLIB}")

# On MacOs the compiler version is not appended
if(${CMAKE_SYSTEM_NAME} STREQUAL "Darwin")
set(RUST_TARGET_TRIPLE "x86_64-apple-darwin")
else()
set(RUST_TARGET_TRIPLE "x86_64-unknown-linux-gnu")
endif()

find_package(LLVM 7 QUIET CONFIG)

if (NOT LLVM_FOUND) 
	find_package(LLVM 6 REQUIRED CONFIG)	
endif()

message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION}")
if (${LLVM_PACKAGE_VERSION} VERSION_LESS 6.0)
  message(FATAL_ERROR "LLVM 6.0 or newer is required")
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(LLVM_BUILD_TOOLS ON)

find_package(ZLIB REQUIRED)
find_package(BISON REQUIRED)
find_package(FLEX REQUIRED)
find_package(GMP REQUIRED)
find_package(Boost REQUIRED COMPONENTS unit_test_framework)

link_directories(${LLVM_LIBRARY_DIR})
include_directories(${LLVM_INCLUDE_DIR})
include_directories (${PROJECT_SOURCE_DIR}/include)

set(CMAKE_INSTALL_PREFIX "install")

# Find the libraries that correspond to the LLVM components
# that we wish to use
llvm_map_components_to_libnames(llvm_libs support core irreader)

macro(kllvm_add_tool name)
  add_executable(${name} ${ARGN})

  # Link against LLVM libraries
  llvm_config(${name})
if(${CMAKE_SYSTEM_NAME} STREQUAL "Darwin")
  target_link_libraries(${name} PUBLIC "-ljemalloc" "-Wl,-rpath /usr/local/lib")
else()
  target_link_libraries(${name} PUBLIC "-ljemalloc" "-Wl,-rpath=/usr/local/lib")
endif()
endmacro(kllvm_add_tool)

install(
  FILES runtime/main/main.ll
  DESTINATION lib/kllvm/llvm/main
)

find_program(OPT opt-7)
find_program(OPT opt-6.0)
find_program(OPT opt)
if(${OPT} STREQUAL "OPT-NOTFOUND")
  message(FATAL_ERROR "Could not find an opt binary. Is llvm installed on your PATH?")
endif()

file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/bin)
configure_file(bin/llvm-kompile bin @ONLY)
configure_file(bin/llvm-kompile-clang bin @ONLY)
configure_file(bin/llvm-kompile-rust-lto bin @ONLY)

install(
  PROGRAMS ${CMAKE_CURRENT_BINARY_DIR}/bin/llvm-kompile ${CMAKE_CURRENT_BINARY_DIR}/bin/llvm-kompile-clang ${CMAKE_CURRENT_BINARY_DIR}/bin/llvm-kompile-matching ${CMAKE_CURRENT_BINARY_DIR}/bin/llvm-kompile-rust-lto
  DESTINATION bin
)

install(
  DIRECTORY include/runtime
  DESTINATION include
)

install(
  DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/include/config
  DESTINATION include
)

set(NOT_YOUNG_OBJECT_BIT 0x10000000000000)
set(YOUNG_AGE_BIT 0x8000000000000)
set(FWD_PTR_BIT 0x20000000000000)
set(LAYOUT_OFFSET 54)
set(HDR_MASK -15762598695796737)

set(MAP_LAYOUT 1)
set(LIST_LAYOUT 2)
set(SET_LAYOUT 3)
set(INT_LAYOUT 4)
set(FLOAT_LAYOUT 5)
set(STRINGBUFFER_LAYOUT 6)
set(BOOL_LAYOUT 7)
set(SYMBOL_LAYOUT 8)

configure_file(config/macros.h include/config/macros.h @ONLY)

file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/runtime)
configure_file(runtime/equality.ll runtime @ONLY)
configure_file(runtime/finish_rewriting.ll runtime @ONLY)
configure_file(runtime/getTag.ll runtime @ONLY)
configure_file(runtime/hash.ll runtime @ONLY)
configure_file(runtime/move_float.ll runtime @ONLY)
configure_file(runtime/move_int.ll runtime @ONLY)
configure_file(runtime/rustalloc.ll runtime @ONLY)
configure_file(runtime/string_equal.ll runtime @ONLY)
configure_file(runtime/take_steps.ll runtime @ONLY)

FILE(GLOB LLVMFiles ${CMAKE_CURRENT_BINARY_DIR}/runtime/*.ll)

install(
  FILES ${LLVMFiles}
  DESTINATION lib/kllvm/llvm
)

FILE(GLOB_RECURSE HaskellSources matching/src/*.hs matching/app/Main.hs)

add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/bin/llvm-kompile-matching
  DEPENDS ${HaskellSources}
  COMMAND stack build
  COMMAND stack install --local-bin-path ${CMAKE_CURRENT_BINARY_DIR}/bin
  WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}/matching
)

add_custom_target(matching
  ALL DEPENDS bin/llvm-kompile-matching
)

# Auto-generated header path
set(KLLVM_AUTOGEN_INCLUDE_DIR ${CMAKE_CURRENT_BINARY_DIR}/include)
include_directories(${KLLVM_AUTOGEN_INCLUDE_DIR})

add_subdirectory(lib)
add_subdirectory(tools)
add_subdirectory(runtime)
add_subdirectory(unittests)
#add_subdirectory(test)
