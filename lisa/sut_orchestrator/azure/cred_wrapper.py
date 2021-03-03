# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

# copy from https://gist.github.com/lmazuel/cc683d82ea1d7b40208de7c9fc8de59d to
#   be compatible with azure-mgmt-marketplaceordering=0.2.1. Once it's upgrade,
#   the wrapper can be removed.
# Wrap credentials from azure-identity to be compatible with SDK that needs msrestazure
#   or azure.common.credentials
# Need msrest >= 0.6.0
# See also https://pypi.org/project/azure-identity/
from typing import Any

from azure.core.pipeline import PipelineContext, PipelineRequest
from azure.core.pipeline.policies import BearerTokenCredentialPolicy
from azure.core.pipeline.transport import HttpRequest
from azure.identity import DefaultAzureCredential  # type: ignore
from msrest.authentication import BasicTokenAuthentication


class CredentialWrapper(BasicTokenAuthentication):
    def __init__(
        self,
        credential: Any = None,
        resource_id: str = "https://management.azure.com/.default",
        **kwargs: Any,
    ):
        """Wrap any azure-identity credential to work with SDK that needs
            azure.common.credentials/msrestazure.

        Default resource is ARM (syntax of endpoint v2)

        :param credential: Any azure-identity credential (DefaultAzureCredential by
                            default)
        :param str resource_id: The scope to use to get the token (default ARM)
        """
        super(CredentialWrapper, self).__init__(dict())
        if credential is None:
            credential = DefaultAzureCredential()
        self._policy = BearerTokenCredentialPolicy(credential, resource_id, **kwargs)

    def _make_request(self) -> PipelineRequest:  # type:ignore
        return PipelineRequest(
            HttpRequest("CredentialWrapper", "https://fakeurl"),
            PipelineContext(None),  # type:ignore
        )

    def set_token(self) -> None:
        """Ask the azure-core BearerTokenCredentialPolicy policy to get a token.

        Using the policy gives us for free the caching system of azure-core.
        We could make this code simpler by using private method, but by definition
        I can't assure they will be there forever, so mocking a fake call to the policy
        to extract the token, using 100% public API."""
        request = self._make_request()
        self._policy.on_request(request)
        # Read Authorization, and get the second part after Bearer
        token = request.http_request.headers["Authorization"].split(" ", 1)[1]
        self.token = {"access_token": token}

    def signed_session(self, session: Any = None) -> Any:
        self.set_token()
        return super(CredentialWrapper, self).signed_session(session)


if __name__ == "__main__":
    import os

    credentials = CredentialWrapper()
    subscription_id = os.environ.get("AZURE_SUBSCRIPTION_ID", "<subscription_id>")

    from azure.mgmt.resource import ResourceManagementClient  # type:ignore

    client = ResourceManagementClient(credentials, subscription_id)
    for rg in client.resource_groups.list():
        print(rg.name)
