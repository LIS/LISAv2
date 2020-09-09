from lisa import TestCaseMetadata, TestSuite, TestSuiteMetadata
from lisa.operating_system import Linux
from lisa.tools import Echo, Uname


@TestSuiteMetadata(
    area="demo",
    category="simple",
    description="""
    this is an example test suite.
    it helps to understand how to write a test case.
    """,
    tags=["demo"],
)
class HelloWorld(TestSuite):
    @TestCaseMetadata(
        description="""
        this test case use default node to
            1. get system info
            2. echo hello world!
        """,
        priority=1,
    )
    def hello(self) -> None:
        self.log.info(f"node count: {len(self.environment.nodes)}")
        node = self.environment.default_node

        if node.os.is_linux:
            assert isinstance(node.os, Linux)
            info = node.tools[Uname].get_linux_information()
            self.log.info(
                f"release: '{info.kernel_release}', version: '{info.kernel_version}', "
                f"hardware: '{info.hardware_platform}', os: '{info.operating_system}'"
            )
        else:
            self.log.info("windows operating system")

        # get process output directly.
        echo = node.tools[Echo]
        result = echo.run("hello world!")
        self.log.info(f"stdout of node: '{result.stdout}'")
        self.log.info(f"stderr of node: '{result.stderr}'")
        self.log.info(f"exitCode of node: '{result.exit_code}'")

    @TestCaseMetadata(
        description="""
        demonstrate a simple way to run command in one line.
        """,
        priority=2,
    )
    def bye(self) -> None:
        node = self.environment.default_node
        # use it once like this way before use short cut
        node.tools[Echo]
        self.log.info(f"stdout of node: '{node.tools.echo('bye!')}'")

    def before_suite(self) -> None:
        self.log.info("setup my test suite")
        self.log.info(f"see my code at {__file__}")

    def after_suite(self) -> None:
        self.log.info("clean up my test suite")

    def before_case(self) -> None:
        self.log.info("before test case")

    def after_case(self) -> None:
        self.log.info("after test case")
