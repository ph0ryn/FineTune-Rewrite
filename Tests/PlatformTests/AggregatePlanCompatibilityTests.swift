// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune at upstream revision 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Original: FineTuneTests/AggregatePlanTests.swift

import Testing

@testable import FineTunePlatform

@Suite("Compat: ProcessTapController — Aggregate Planning")
struct UpstreamAggregatePlanTests {
  @Test("Single plain device: unchanged, stays stacked")
  func singlePlainDevice() {
    let plan = AggregateLayoutPlanner.plan(
      outputUIDs: ["builtin"],
      expand: { _ in nil },
      outputStreamCount: { _ in 1 }
    )
    #expect(plan.subDeviceUIDs == ["builtin"])
    #expect(plan.isStacked == true)
    #expect(plan.clockDeviceUID == "builtin")
  }

  @Test("Single aggregate around a single-stream device: flattened and NOT stacked")
  func singleAggregateFlattened() {
    let plan = AggregateLayoutPlanner.plan(
      outputUIDs: ["agg"],
      expand: { $0 == "agg" ? ["scarlett"] : nil },
      outputStreamCount: { _ in 1 }
    )
    #expect(plan.subDeviceUIDs == ["scarlett"])
    #expect(plan.isStacked == false)
    #expect(plan.clockDeviceUID == "scarlett")
  }

  @Test("Single aggregate around a multi-stream device: stays stacked")
  func singleAggregateMultiStreamDevice() {
    let plan = AggregateLayoutPlanner.plan(
      outputUIDs: ["agg"],
      expand: { $0 == "agg" ? ["motu"] : nil },
      outputStreamCount: { _ in 2 }
    )
    #expect(plan.subDeviceUIDs == ["motu"])
    #expect(plan.isStacked == true)
  }

  @Test("Single aggregate with multiple sub-devices: flattened, stays stacked, order preserved")
  func singleAggregateMultipleSubDevices() {
    let plan = AggregateLayoutPlanner.plan(
      outputUIDs: ["agg"],
      expand: { $0 == "agg" ? ["devA", "devB"] : nil },
      outputStreamCount: { _ in 1 }
    )
    #expect(plan.subDeviceUIDs == ["devA", "devB"])
    #expect(plan.isStacked == true)
    #expect(plan.clockDeviceUID == "devA")
  }

  @Test("Multi-device mirroring: stays stacked, order preserved")
  func multiDeviceMirroring() {
    let plan = AggregateLayoutPlanner.plan(
      outputUIDs: ["a", "b"],
      expand: { _ in nil },
      outputStreamCount: { _ in 1 }
    )
    #expect(plan.subDeviceUIDs == ["a", "b"])
    #expect(plan.isStacked == true)
    #expect(plan.clockDeviceUID == "a")
  }

  @Test("Mirroring that includes an aggregate: aggregate flattened but stays stacked (mirror)")
  func mirroringWithAggregate() {
    let plan = AggregateLayoutPlanner.plan(
      outputUIDs: ["agg", "speaker"],
      expand: { $0 == "agg" ? ["scarlett"] : nil },
      outputStreamCount: { _ in 1 }
    )
    #expect(plan.subDeviceUIDs == ["scarlett", "speaker"])
    #expect(plan.isStacked == true)
    #expect(plan.clockDeviceUID == "scarlett")
  }

  @Test("Duplicate hardware devices across flattening are de-duplicated, order preserved")
  func deduplicatesSubDevices() {
    let plan = AggregateLayoutPlanner.plan(
      outputUIDs: ["agg", "scarlett"],
      expand: { $0 == "agg" ? ["scarlett", "canton"] : nil },
      outputStreamCount: { _ in 1 }
    )
    #expect(plan.subDeviceUIDs == ["scarlett", "canton"])
    #expect(plan.isStacked == true)
  }

  @Test("Empty aggregate sub-device list is treated as a plain device")
  func emptyAggregateTreatedAsPlain() {
    let plan = AggregateLayoutPlanner.plan(
      outputUIDs: ["agg"],
      expand: { _ in [] },
      outputStreamCount: { _ in 1 }
    )
    #expect(plan.subDeviceUIDs == ["agg"])
    #expect(plan.isStacked == true)
  }
}

@Suite("Compat: ProcessTapController — IO Proc input stream usage")
struct UpstreamInputStreamUsageTests {
  @Test("Duplex device (mic + tap): hardware mic stream disabled, tap kept")
  func duplexDisablesMicKeepsTap() {
    let flags = AggregateLayoutPlanner.inputStreamUsageFlags(inputCount: 2, outputCount: 1)
    #expect(flags == [0, 1])
  }

  @Test("Output-only device (tap only): nothing to disable")
  func outputOnlyNoChange() {
    #expect(AggregateLayoutPlanner.inputStreamUsageFlags(inputCount: 1, outputCount: 1) == nil)
  }

  @Test("Multiple hardware inputs before the tap are all disabled")
  func multipleHardwareInputsDisabled() {
    let flags = AggregateLayoutPlanner.inputStreamUsageFlags(inputCount: 4, outputCount: 1)
    #expect(flags == [0, 0, 0, 1])
  }

  @Test("Keeps the trailing outputCount input streams when several outputs exist")
  func keepsTrailingByOutputCount() {
    let flags = AggregateLayoutPlanner.inputStreamUsageFlags(inputCount: 3, outputCount: 2)
    #expect(flags == [0, 1, 1])
  }

  @Test("No input streams: nil")
  func noInputs() {
    #expect(AggregateLayoutPlanner.inputStreamUsageFlags(inputCount: 0, outputCount: 1) == nil)
  }

  @Test("Zero output streams (or a failed stream-count read): nil, never an all-unused map")
  func zeroOutputCountNeverDisablesTap() {
    #expect(AggregateLayoutPlanner.inputStreamUsageFlags(inputCount: 2, outputCount: 0) == nil)
  }
}
