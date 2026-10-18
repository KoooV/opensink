cmake_minimum_required(VERSION 3.13)
project(app_linux_runner LANGUAGES CXX)

add_executable(app_linux main.cc)

target_compile_features(app_linux PRIVATE cxx_std_14)
