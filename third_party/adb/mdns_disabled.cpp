// Copyright 2026 006IDC. Licensed under the Apache License, Version 2.0.
// android-tools 37.0.0 does not build either upstream mDNS backend.
// This distribution deliberately supports explicit IP:port pairing/connect only.
// Do not report a functioning discovery backend when none was linked.
#include <cstdlib>
void StartAdbMdnsDiscovery() { setenv("ADB_MDNS", "0", 1); }
void StartOpenScreenDiscovery() { StartAdbMdnsDiscovery(); }
