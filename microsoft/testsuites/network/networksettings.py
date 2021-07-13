# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

from assertpy import assert_that

from lisa import Node, TestCaseMetadata, TestSuite, TestSuiteMetadata
from lisa.tools import Ethtool


@TestSuiteMetadata(
    area="network",
    category="functional",
    description="""
    This test suite runs the ethtool related network test cases.
    """,
)
class NetworkSettings(TestSuite):
    @TestCaseMetadata(
        description="""
            This test case verifies if ring buffer settings can be changed with ethtool.

            Steps:
            1. Get the current ring buffer settings.
            2. Change the rx and tx value to new_values using ethtool.
            3. Get the settings again and validate the current rx and tx
                values are equal to the new_values assigned.

        """,
        priority=1,
    )
    def validate_ringbuffer_settings_change(self, node: Node) -> None:
        ethtool = node.tools[Ethtool]
        devices_settings = ethtool.get_all_device_ring_buffer_settings()

        for interface_settings in devices_settings:
            interface = interface_settings.device_name
            original_rx = int(interface_settings.current_ring_buffer_settings["RX"])
            original_tx = int(interface_settings.current_ring_buffer_settings["TX"])

            modified_rx = 10011
            modified_tx = 190
            modified_settings = ethtool.change_device_ring_buffer_settings(
                interface, modified_rx, modified_tx
            )
            assert_that(
                modified_settings.current_ring_buffer_settings["RX"],
                "Changing RX Ringbuffer setting didn't succeed",
            ).is_equal_to(modified_rx)
            assert_that(
                modified_settings.current_ring_buffer_settings["TX"],
                "Changing TX Ringbuffer setting didn't succeed",
            ).is_equal_to(modified_tx)

            # Revert the settings back to original values
            reverted_settings = ethtool.change_device_ring_buffer_settings(
                interface, original_rx, original_tx
            )
            assert_that(
                reverted_settings.current_ring_buffer_settings["RX"],
                "Reverting RX Ringbuffer setting to original value didn't succeed",
            ).is_equal_to(original_rx)
            assert_that(
                reverted_settings.current_ring_buffer_settings["TX"],
                "Reverting TX Ringbuffer setting to original value didn't succeed",
            ).is_equal_to(original_tx)
