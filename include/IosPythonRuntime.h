#pragma once

#include <cstdint>
#include <string>

namespace IosPythonRuntime {

bool Resolve();
bool IsResolved();
bool IsPythonInitialized();
bool Execute(const std::string& code, std::string* outError = nullptr);
std::string GetDiagnostics();

} // namespace IosPythonRuntime
