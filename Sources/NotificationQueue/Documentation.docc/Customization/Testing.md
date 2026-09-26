# Testing

Exercise scheduling behaviour with replaceable notification and journal stores.

## Overview

The XCTest suite covers batch replacement/removal, overflow and restart, concurrent updates, cancellation, failed writes/additions/removals, silent OS drops, external queue usage, warning timing and suppression, and journal corruption. The fake-store tests do not require a simulator or notification permission.
