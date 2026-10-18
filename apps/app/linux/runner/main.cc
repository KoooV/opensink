#include <flutter/flutter.h>

int main(int argc, char** argv) {
  return flutter::RunDartEntrypoint(
      flutter::DartProject(argc, argv), "main");
}
