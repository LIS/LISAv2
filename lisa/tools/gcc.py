# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

from typing import cast

from lisa.executable import Tool
from lisa.operating_system import Posix


class Gcc(Tool):
    @property
    def command(self) -> str:
        return "gcc"

    @property
    def can_install(self) -> bool:
        return True

    def compile(self, filename: str, output: str = "") -> None:
        if output:
            self.run(f"{filename} -o {output}")
            self.node.execute(f"cp {output} /usr/local/bin", sudo=True)
        else:
            self.run(filename)

    def _install(self) -> bool:
        posix_os: Posix = cast(Posix, self.node.os)
        posix_os.install_packages("gcc")
        return self._check_exists()
