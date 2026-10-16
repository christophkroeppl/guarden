"""The one image reference a service that builds its own container carries.

`weedr service build` tags an image and `loom` writes the `Image=` a unit
carries. They are two halves of one contract and the spec states it as one
sentence (§6.6 step 2): the build is tagged **with the image reference the
manifest names**. A service's unit source is the source of truth for that
reference — a Compose service's `image:`, a quadlet unit's `Image=` — so this
module is what both halves read rather than the copy that drifts.

**The reference is local (`localhost/`), and that is a property of the build,
not of the reference.** A rootless `podman build` runs in the service user's own
store, so the only place the image can be read from is that store: an `Image=`
naming a registry would ask for a pull from a namespace nothing pushed to, and
the deploy would fail image-not-found. Tagging the same local reference is what
makes the two halves agree.

**A service may declare more than one container, so the reference is a function
of the container.** The single-container case is the common one and the shape
of the spec's sentence, but the lookup is per container and a second container
that also builds gets its own reference; a single name would collide two
services' images into one tag.
"""

from __future__ import annotations

import re
from pathlib import Path

from guarden import compose, unitsource

# The local reference prefix and the tag the build writes. One constant because
# the mutator's build and the renderer's `Image=` have to name the same image,
# and two literals would be the copy that drifts.
LOCAL_PREFIX = "localhost"
BUILD_TAG = "latest"

# The directory a hand-written unit source lives in, and the two spellings this
# module reads. `.guarden/quadlet/` is the renderer's own spelling (spec 2.1);
# `compose.yaml` at the root is the other, and a repository ships exactly one of
# them. Both are the constants the renderer reads, imported rather than retyped
# so the build and the render cannot disagree about where the source is.
QUADLET_DIR = Path(".guarden") / "quadlet"
COMPOSE_REL = Path("compose.yaml")

# `localhost/<name>:<tag>`: the name is the service, so it matches what the
# service is called rather than a namespace that does not exist on this host. A
# tag is required: a bare name reads as `:latest` anyway, and writing it is what
# keeps the reference explicit.
REFERENCE = re.compile(rf"^{re.escape(LOCAL_PREFIX)}/([a-z0-9][a-z0-9._-]*):([^/\s]+)$")


def reference_for(service: str) -> str:
    """`localhost/<service>:<tag>`: the image one service builds for itself.

    The service name is the part that distinguishes two services, so two
    services building the same base image never write one another's image, and
    a redeploy overwrites the one it is replacing.
    """
    return f"{LOCAL_PREFIX}/{service}:{BUILD_TAG}"


def parse(reference: str) -> tuple[str, str] | None:
    """`localhost/<name>:<tag>` as `(name, tag)`, or `None` if it is not one.

    **Never raises.** A reference that is not this shape is not this module's
    business: an untagged or registry-qualified name is the repository's own
    spelling and the renderer passes it through verbatim. The caller asks
    whether a parsed pair came back and the pattern is a closed one, so a name
    or a tag that is empty answers `None` rather than half a reference.
    """
    found = REFERENCE.match(reference.strip())
    if found is None:
        return None
    return found.group(1), found.group(2)


def unit_image(directory: Path, container: str) -> str | None:
    """The image a service's own unit source declares for `container`.

    Read from the source in the service's home — the same tree `loom` renders,
    so a rebuild and a re-render read the same bytes. A Compose service's
    `image:` and a quadlet unit's `Image=` are one fact in two spellings; a
    container that declares neither (a `build:` service with no `image:`) has
    nothing to read and gets `None`, which the caller answers with the built
    reference.
    """
    compose_file = directory / COMPOSE_REL
    if compose_file.is_file():
        body = compose.services(compose.document(compose_file), compose_file).get(container) or {}
        declared = body.get("image")
        return declared.strip() if isinstance(declared, str) and declared.strip() else None
    unit_file = directory / QUADLET_DIR / f"{container}.container"
    if unit_file.is_file():
        declared = unitsource.parse(unit_file).one("Container", "Image")
        return declared.strip() if declared and declared.strip() else None
    return None


def declared_or_built(directory: Path, service: str, container: str) -> str:
    """The reference a service's source declares, or the one its build writes.

    **A source that declares no image still gets a reference**, and it is the
    local one the build tags. A Compose service with `build:` and no `image:`
    has no name to tag, so the local reference is exactly what that case
    produces; refusing would leave the service with no image reference at all,
    which is the worse of the two. A source that declares a registry image is
    returned verbatim: that is a pull, and only a source with no image at all
    is a build.
    """
    return unit_image(directory, container) or reference_for(service)
