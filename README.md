# LXMFSwift

A Swift implementation of [LXMF](https://github.com/markqvist/LXMF) (Lightweight Extensible Message Format) for asynchronous, encrypted messaging over [Reticulum](https://reticulum.network) networks.

## Requirements

- Swift 5.9+
- macOS 13+ / iOS 16+
- [ReticulumSwift](https://github.com/torlando-tech/reticulum-swift)

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/torlando-tech/LXMF-swift.git", from: "0.1.0"),
]
```

## Overview

- **LXMRouter** — Message routing with direct, propagated, and opportunistic delivery
- **LXMessage** — Structured messages with fields, timestamps, and delivery receipts
- **Propagation** — Store-and-forward via propagation nodes with stamp-based anti-spam
- **Storage** — Local message persistence with GRDB

## Acknowledgements
- This work was partially funded by the [Solarpunk Pioneers Fund](https://solarpunk-pioneers.org)
- K8 and 405nm for generously donating for an iPhone
- [Reticulum](https://reticulum.network), [LXMF](https://github.com/markqvist/LXMF) and [LXST](https://github.com/markqvist/LXST) by Mark Qvist
## License

Copyright (c) 2026 Torlando Tech LLC.

Licensed under the [Mozilla Public License 2.0](LICENSE).
