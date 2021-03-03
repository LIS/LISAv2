# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

import re
from typing import Any, Optional, Type

from assertpy import assert_that  # type: ignore

from lisa.executable import Tool


class Lscpu(Tool):
    __pattern_cores_per_socket = re.compile(
        r"^Core\(s\) per socket:[ ]+([\d]+)\r?$", re.M
    )
    __pattern_sockets = re.compile(r"^Socket\(s\):[ ]+([\d]+)\r?$", re.M)

    def _initialize(self, *args: Any, **kwargs: Any) -> None:
        self._core_count: Optional[int] = None

    @property
    def command(self) -> str:
        return "lscpu"

    @classmethod
    def _windows_tool(cls) -> Optional[Type[Tool]]:
        return WindowsLscpu

    def _check_exists(self) -> bool:
        return True

    def get_core_count(self, force: bool = False) -> int:
        if self._core_count is None or force:
            result = self.run()
            matched = self.__pattern_cores_per_socket.findall(result.stdout)
            assert_that(
                len(matched),
                f"cores per socket should have exact one line, but got {matched}",
            ).is_equal_to(1)
            core_per_socket = int(matched[0])
            matched = self.__pattern_sockets.findall(result.stdout)
            assert_that(
                len(matched),
                f"sockets should have exact one line, but got {matched}",
            ).is_equal_to(1)
            sockets = int(matched[0])
            self._core_count = sockets * core_per_socket
        return self._core_count


class WindowsLscpu(Lscpu):
    @property
    def command(self) -> str:
        return "wmic cpu get"

    def get_core_count(self, force: bool = False) -> int:
        if self._core_count is None or force:
            result = self.run("ThreadCount")
            lines = result.stdout.splitlines(keepends=False)
            assert "ThreadCount" == lines[0].strip(), f"actual: '{lines[0]}'"
            self._core_count = int(lines[2].strip())
        return self._core_count
