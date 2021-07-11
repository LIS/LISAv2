# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

from lisa.executable import Tool
from lisa.util.process import ExecutableResult


class Systemctl(Tool):
    @property
    def command(self) -> str:
        return "systemctl"

    @property
    def can_install(self) -> bool:
        return False

    def check_exists(self) -> bool:
        cmd_result = self.node.execute(
            "ls -lt /run/systemd/system", shell=True, sudo=True
        )
        return 0 == cmd_result.exit_code

    def check_service_exists(self, name: str) -> bool:
        cmd_result = self.run(f"status {name}", shell=True, sudo=True)
        return cmd_result.exit_code == 0

    def stop_service(self, name: str) -> None:
        if self.check_service_exists(name):
            cmd_result = self.run(f"stop {name}", shell=True, sudo=True)
            cmd_result.assert_exit_code()

    def restart_service(self, name: str) -> ExecutableResult:
        return self.run(f"{name} restart", shell=True, sudo=True)
