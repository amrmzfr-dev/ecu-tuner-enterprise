// Mock ECU server for CI -- never test against real hardware in CI
#include <iostream>
int main() {
    std::cout << "Mock ECU server running..." << std::endl;
}
