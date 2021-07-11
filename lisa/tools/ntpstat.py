# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.
from typing import cast

from retry import retry

from lisa.executable import Tool
from lisa.operating_system import Posix
from lisa.util import LisaException

from .gcc import Gcc
from .git import Git


class Ntpstat(Tool):
    repo = "https://github.com/darkhelmet/ntpstat"
    __not_sync = "unsynchronised"

    @property
    def command(self) -> str:
        return "ntpstat"

    @property
    def can_install(self) -> bool:
        return True

    def _install_from_src(self) -> None:
        posix_os: Posix = cast(Posix, self.node.os)
        posix_os.install_packages([Git, Gcc])
        tool_path = self.get_tool_path()
        self.node.shell.mkdir(tool_path, exist_ok=True)
        git = self.node.tools[Git]
        git.clone(self.repo, tool_path)
        gcc = self.node.tools[Gcc]
        code_path = tool_path.joinpath("ntpstat")
        gcc.compile(f"{code_path}/ntpstat.c", "ntpstat")

    def install(self) -> bool:
        if not self._check_exists():
            posix_os: Posix = cast(Posix, self.node.os)
            package_name = "ntpstat"
            posix_os.install_packages(package_name)
            if not self._check_exists():
                self._install_from_src()
        return self._check_exists()

    @retry(exceptions=LisaException, tries=10, delay=2)
    def check_time_sync(self) -> None:
        cmd_result = self.run(shell=True, sudo=True, force_run=True)
        if self.__not_sync in cmd_result.stdout:
            raise LisaException("Local time is unsynchronised with time server.")
