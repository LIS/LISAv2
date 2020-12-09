from datetime import timedelta
from time import sleep
from typing import Any

from lisa.executable import Tool
from lisa.util import LisaException
from lisa.util.perf_timer import create_timer
from lisa.util.process import ExecutableResult

from .date import Date
from .uptime import Uptime
from .who import Who


class Reboot(Tool):
    def _initialize(self, *args: Any, **kwargs: Any) -> None:
        # timeout to wait
        self.time_out: int = 300

    @property
    def command(self) -> str:
        return "reboot"

    def _check_exists(self) -> bool:
        return True

    def reboot(self) -> None:
        who = self.node.tools[Who]
        timer = create_timer()

        # who -b doesn't return correct content in Ubuntu 14.04, but uptime works.
        # uptime has no -s parameter in some distros, so not use is as default.
        try:
            last_boot_time = who.last_boot()
        except Exception:
            uptime = self.node.tools[Uptime]
            last_boot_time = uptime.since_time()
        current_boot_time = last_boot_time

        # who -b returns time without seconds.
        # so if the node rebooted in one minute, the who -b is not changed.
        # The reboot will wait forever.
        # in this case, verify the time is wait enough to prevent this problem.
        date = self.node.tools[Date]
        # boot time has no tzinfo, so remove from date result to avoid below error.
        # TypeError: can't subtract offset-naive and offset-aware datetimes
        current_delta = date.current().replace(tzinfo=None) - current_boot_time
        self._log.debug(f"delta time since last boot: {current_delta}")
        while current_delta < timedelta(minutes=1):
            # wait until one minute
            wait_seconds = 60 - current_delta.seconds + 1
            self._log.debug(f"waiting {wait_seconds} seconds before rebooting")
            sleep(wait_seconds)
            current_delta = date.current().replace(tzinfo=None) - current_boot_time

        self._log.debug(f"rebooting with boot time: {last_boot_time}")
        try:
            reboot_result: ExecutableResult = self.node.execute(f"sudo {self.command}")
            if reboot_result.stderr:
                self.node.execute_async(f"sudo /usr/sbin/{self.command}")
        except Exception as identifier:
            # it doesn't matter to exceptions here. The system may reboot fast
            self._log.debug(f"ignorable exception on rebooting: {identifier}")

        connected: bool = False
        while (
            last_boot_time >= current_boot_time and timer.elapsed(False) < self.time_out
        ):
            try:
                self.node.close()
                current_boot_time = who.last_boot()
                connected = True
            except Exception as identifier:
                # error is ignorable, as ssh may be closed suddenly.
                self._log.debug(f"ignorable ssh exception: {identifier}")
            self._log.debug(f"reconnected with uptime: {current_boot_time}")
        if timer.elapsed() > self.time_out:
            if connected:
                raise LisaException(
                    "timeout to wait reboot, the node may not perform reboot."
                )
            else:
                raise LisaException(
                    "timeout to wait reboot, the node may stuck on reboot command."
                )
