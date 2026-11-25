# Delivery to Dokploy

How a service meets [the deployment contract](delivery.md#the-deployment-contract) on Dokploy, which runs each environment on Docker Swarm. Setting up Dokploy and its servers is the platform's, outside this skill ([out of scope](system.md#out-of-scope)).

## Applications

An environment runs a service's image as one Dokploy application per command ([commands](composition.md#commands)): `loans migrate`, `loans serve` and `loans worker run`, and one application for the gateway.

- `deploy_dokploy.yml` deploys them in `application_ids`' order. `run_to_completion_application_ids` lists `loans migrate`, so it deploys serve only once migrate's container of the new image exits 0.
- The migrate application has no health check, and its Swarm settings in Dokploy give it a restart policy whose condition is `none` and an update config whose failure action is `continue`, as `swift-microservices/ci` requires of an application that runs to completion.
- A client dials its upstream's `tasks.<service>`, which resolves to every replica, rather than the service's one virtual address ([transports](grpc.md#transports)).

## Staging and production

Loans' `ci.yml` adds this job after `ci`:

```yaml
  staging:
    name: Staging
    needs: [ci]
    if: github.event_name == 'push'
    permissions:
      contents: read
      actions: read
      packages: read
    uses: swift-microservices/ci/.github/workflows/deploy_dokploy.yml@<commit>  # <release>
    with:
      environment: staging
      image_repository: ghcr.io/bookshelf/bookshelf-loans
      application_ids: '["<loans migrate>", "<loans serve>", "<loans worker>"]'
      run_to_completion_application_ids: '["<loans migrate>"]'
    secrets:
      DOKPLOY_URL: ${{ secrets.DOKPLOY_URL }}
      DOKPLOY_TOKEN: ${{ secrets.DOKPLOY_TOKEN }}
```

- `deploy.yml`'s job has the same `permissions` and calls `deploy_dokploy.yml` with `environment: production`, its `commit`, the `image_repository`, the production `application_ids` and `run_to_completion_application_ids`, and the Dokploy secrets.
- Secrets: `DOKPLOY_URL` and `DOKPLOY_TOKEN`, a Dokploy API key that can read, update and deploy the service's applications and read their containers, which the deploy reads to wait for the new image.
