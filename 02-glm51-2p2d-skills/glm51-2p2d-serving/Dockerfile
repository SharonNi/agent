# =============================================================================
# Customer-facing nixl release image for GLM-5.1
#
# Based on: customer-h200 Dockerfile architecture
# KV Transport: nixl 1.0.1 LIBFABRIC backend (instead of Mooncake)
# Target: AWS p5en (H200, sm_90) with EFA
#
# Key components:
#   - SGLang 0.5.10 with nixl KV transfer backend
#   - nixl 1.0.1 (LIBFABRIC plugin for EFA) - KV Cache传输
#   - UCCL-EP (MoE AlltoAll通信, deep_ep wrapper) - Expert路由
#   - EFA installer 1.47 + libfabric + NCCL 2.23.4 + aws-ofi-nccl 1.19
#   - PyTorch 2.9.1+cu128, CUDA 13 runtime
#   - UCX 1.18.0 (nixl dependency)
#
# Multi-stage: STAGE 1 builder, STAGE 2 runtime.
# Expected final size: ~11-12 GB
# =============================================================================

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
ARG BASE_IMAGE=nvidia/cuda:13.0.2-cudnn-devel-ubuntu22.04
ARG EFA_INSTALLER_VERSION=1.47.0
ARG NCCL_VERSION=v2.23.4-1
ARG AWS_OFI_NCCL_VERSION=v1.19.0
ARG SGLANG_VERSION=0.5.10
ARG NIXL_VERSION=ac46102d8d1c971e5f36a5568cbd3b8a2ca23cb1
ARG NIXL_REPO=https://github.com/xqun3/nixl.git
ARG UCX_VERSION=v1.18.0
ARG UCCL_REPO=https://github.com/uccl-project/uccl.git
ARG UCCL_REF=8ac850bd
ARG TORCH_CUDA_ARCH_LIST=9.0

# Release labels
ARG IMAGE_VERSION=dev
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown

# =============================================================================
# STAGE 1: BUILDER
# =============================================================================
FROM ${BASE_IMAGE} AS builder

ARG EFA_INSTALLER_VERSION
ARG NCCL_VERSION
ARG AWS_OFI_NCCL_VERSION
ARG SGLANG_VERSION
ARG NIXL_VERSION
ARG NIXL_REPO
ARG UCX_VERSION
ARG UCCL_REPO
ARG UCCL_REF
ARG TORCH_CUDA_ARCH_LIST

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST} \
    MAX_JOBS=32

# ---- System deps ----
# Note: Skip 'meson' from apt - will install newer version via pip
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.10 python3.10-dev python3-pip python3-setuptools python3-wheel python3-venv \
      build-essential cmake ninja-build pkg-config patchelf clang-format-14 \
      git wget curl ca-certificates gnupg2 lsb-release \
      autoconf automake libtool \
      pciutils environment-modules tcl \
      iproute2 ethtool dmidecode \
      rdma-core libibverbs-dev libnl-3-dev libnl-route-3-dev \
      hwloc libhwloc-dev \
      libnuma-dev libudev-dev udev \
      pybind11-dev python3-pybind11 \
      openssh-server openssh-client \
    && ln -sf /usr/bin/python3 /usr/local/bin/python

# ---- EFA installer (userspace libfabric + aws-libfabric; skips kmod) ----
RUN cd /tmp && \
    curl -fsSL https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz -o efa.tar.gz && \
    tar -xzf efa.tar.gz && cd aws-efa-installer && \
    ./efa_installer.sh -y --skip-kmod --skip-limit-conf --no-verify && \
    ldconfig && \
    cd / && rm -rf /tmp/aws-efa-installer /tmp/efa.tar.gz && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/amazon/efa/bin:/opt/amazon/openmpi/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:${LD_LIBRARY_PATH:-}" \
    PKG_CONFIG_PATH="/opt/amazon/efa/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ---- NCCL (use CUDA 13 base's bundled NCCL 2.28.3) ----
# nvidia/cuda:13.0.2-cudnn-devel-ubuntu22.04 ships NCCL 2.28.3 at
# /usr/lib/x86_64-linux-gnu/libnccl.so.2.28.3

# ---- aws-ofi-nccl (NCCL EFA plugin) ----
RUN cd /tmp && \
    git clone --depth 1 -b ${AWS_OFI_NCCL_VERSION} https://github.com/aws/aws-ofi-nccl.git && \
    cd aws-ofi-nccl && \
    ./autogen.sh && \
    ./configure \
      --prefix=/opt/aws-ofi-nccl \
      --with-libfabric=/opt/amazon/efa \
      --with-cuda=/usr/local/cuda \
      --with-nccl=/usr \
      --with-mpi=/opt/amazon/openmpi \
      --enable-platform-aws && \
    make -j"$(nproc)" install && \
    rm -rf /tmp/aws-ofi-nccl

# ---- CUDA 12.8 side-by-side toolchain (for UCCL-EP build) ----
# UCCL's torch C-extension requires CUDA 12.8 to match torch 2.9.1+cu128
RUN wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && rm cuda-keyring_1.1-1_all.deb && \
    apt-get update && apt-get install -y --no-install-recommends \
      cuda-nvcc-12-8 \
      cuda-cudart-dev-12-8 \
      cuda-driver-dev-12-8 \
      libcurand-dev-12-8 \
      libcublas-dev-12-8 \
    && rm -rf /var/lib/apt/lists/*

# ---- Python toolchain + torch (via sglang[all]) ----
RUN python -m pip install --upgrade pip setuptools wheel && \
    python -m pip install "meson>=0.64.0" ninja && \
    python -m pip install \
      "sglang[all]==${SGLANG_VERSION}" \
      hf_transfer orjson aiohttp uvloop psutil && \
    python -m pip install \
      "nanobind>=2.0" "pybind11>=2.11" "numpy<2" \
      packaging \
      "grpcio>=1.60" "grpcio-tools>=1.60" \
      "etcd3>=0.12" "protobuf>=4.25"

# ---- UCX (required by nixl) ----
# Build against libfabric in /opt/amazon/efa for EFA provider access
# Disable CUDA support to avoid CUDA 13.0 incompatibility (UCX 1.18.0 expects CUDA < 13)
RUN git clone --depth 1 -b ${UCX_VERSION} https://github.com/openucx/ucx.git /opt/ucx-src && \
    cd /opt/ucx-src && \
    ./autogen.sh && \
    ./contrib/configure-release \
      --prefix=/opt/ucx \
      --without-cuda \
      --with-verbs \
      --with-rdmacm \
      --enable-mt && \
    make -j"$(nproc)" && make install && \
    ldconfig && \
    rm -rf /opt/ucx-src

ENV PATH="/opt/ucx/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/ucx/lib:${LD_LIBRARY_PATH}" \
    PKG_CONFIG_PATH="/opt/ucx/lib/pkgconfig:${PKG_CONFIG_PATH}"

# ---- nixl (LIBFABRIC plugin only) ----
# Build with LIBFABRIC plugin for EFA access
# Using xqun3 fork with duplicate-fragment fix for PP scenarios
RUN git clone --recursive ${NIXL_REPO} /opt/nixl-src && \
    cd /opt/nixl-src && git fetch origin ${NIXL_VERSION} && git checkout ${NIXL_VERSION} && \
    git submodule update --init --recursive && \
    meson setup build \
      --prefix=/opt/nixl \
      --buildtype=release \
      -Ducx_path=/opt/ucx \
      -Dlibfabric_path=/opt/amazon/efa \
      -Dcudapath_inc=/usr/local/cuda/include \
      -Dcudapath_lib=/usr/local/cuda/lib64 \
      -Denable_plugins=LIBFABRIC \
      -Ddisable_gds_backend=true \
      -Dbuild_tests=false \
      -Dbuild_examples=true && \
    ninja -C build -j"$(nproc)" && \
    ninja -C build install && \
    ldconfig

# ---- UCCL-EP (for MoE AlltoAll) ----
# Build with CUDA 12.8 toolchain to match torch cu128 ABI
RUN git clone --recursive ${UCCL_REPO} /opt/uccl && \
    cd /opt/uccl && git checkout ${UCCL_REF} && \
    git submodule update --init --recursive && \
    cd ep && \
    CUDA_HOME=/usr/local/cuda-12.8 \
    PATH=/usr/local/cuda-12.8/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:${LD_LIBRARY_PATH} \
    NCCL_HOME=/usr/local \
    MPI_HOME=/opt/amazon/openmpi \
    python setup.py install && \
    cd /opt/uccl/ep/deep_ep_wrapper && python setup.py install

# Record build provenance
RUN cd /opt/nixl-src && git rev-parse HEAD > /tmp/nixl-sha.txt && \
    cd /opt/uccl && git rev-parse HEAD > /tmp/uccl-sha.txt && \
    cat /tmp/nixl-sha.txt /tmp/uccl-sha.txt

# Stage CUDA 12.8 runtime libs for UCCL
RUN mkdir -p /opt/cuda128-runtime-libs && \
    cp -a /usr/local/cuda-12.8/targets/x86_64-linux/lib/. /opt/cuda128-runtime-libs/ && \
    echo "staged CUDA 12.8 runtime libs: $(ls /opt/cuda128-runtime-libs | wc -l) files"

# =============================================================================
# STAGE 2: RUNTIME
# =============================================================================
FROM ${BASE_IMAGE} AS runtime

ARG EFA_INSTALLER_VERSION
ARG TORCH_CUDA_ARCH_LIST
ARG IMAGE_VERSION
ARG BUILD_DATE
ARG VCS_REF
ARG NIXL_VERSION
ARG UCCL_REF
ARG SGLANG_VERSION

# OCI metadata labels
LABEL org.opencontainers.image.title="sglang-nixl-uccl" \
      org.opencontainers.image.description="SGLang + nixl LIBFABRIC + UCCL-EP for AWS EFA (H100/H200)" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.vendor="GLM-5.1 Team" \
      aws.efa.installer="${EFA_INSTALLER_VERSION}" \
      aws.nixl.version="${NIXL_VERSION}" \
      aws.uccl.ref="${UCCL_REF}" \
      aws.sglang.version="${SGLANG_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST}

# ---- Minimal runtime system deps ----
# Keep python3.10-dev for triton JIT (needs Python.h)
# Keep ninja-build for SGLang JIT kernel compile (QK-Norm)
# Keep libpython3.10 for nixl python binding dlopen
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.10 python3-pip libpython3.10 python3.10-dev \
      ninja-build \
      libnuma1 libudev1 libhwloc15 \
      rdma-core libibverbs1 libnl-3-200 libnl-route-3-200 \
      iproute2 ethtool pciutils \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/local/bin/python

# ---- EFA userspace (libfabric / aws-libfabric / libefa) ----
COPY --from=builder /opt/amazon /opt/amazon
COPY --from=builder /usr/lib/x86_64-linux-gnu/libefa.so* /usr/lib/x86_64-linux-gnu/
COPY --from=builder /usr/lib/x86_64-linux-gnu/libibverbs /usr/lib/x86_64-linux-gnu/libibverbs
COPY --from=builder /usr/lib/x86_64-linux-gnu/libibverbs.so* /usr/lib/x86_64-linux-gnu/

# ---- NCCL + aws-ofi-nccl ----
COPY --from=builder /opt/aws-ofi-nccl /opt/aws-ofi-nccl

# ---- CUDA 12.8 runtime libs (for UCCL) ----
COPY --from=builder /opt/cuda128-runtime-libs /opt/cuda128-runtime-libs

# ---- UCX runtime libs ----
COPY --from=builder /opt/ucx/lib /opt/ucx/lib

# ---- nixl runtime (libs + plugins + python binding) ----
COPY --from=builder /opt/nixl /opt/nixl

# ---- Python packages (sglang + torch + all deps) ----
COPY --from=builder /usr/local/lib/python3.10/dist-packages /usr/local/lib/python3.10/dist-packages
COPY --from=builder /usr/local/bin/python /usr/local/bin/python

# ---- Environment ----
ENV PATH="/opt/amazon/efa/bin:/opt/amazon/openmpi/bin:/opt/ucx/bin:/opt/nixl/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/opt/aws-ofi-nccl/lib:/opt/ucx/lib:/opt/nixl/lib/x86_64-linux-gnu:/opt/cuda128-runtime-libs:/usr/local/lib/python3.10/dist-packages/torch/lib:${LD_LIBRARY_PATH}" \
    PYTHONPATH="/opt/nixl/lib/python3/dist-packages:${PYTHONPATH}" \
    NIXL_HOME=/opt/nixl \
    NIXL_PLUGIN_DIR="/opt/nixl/lib/x86_64-linux-gnu/plugins" \
    NCCL_NET_PLUGIN="/opt/aws-ofi-nccl/lib/libnccl-net.so" \
    FI_PROVIDER="efa" \
    FI_EFA_USE_DEVICE_RDMA="1" \
    FI_EFA_FORK_SAFE="1" \
    OMPI_ALLOW_RUN_AS_ROOT="1" \
    OMPI_ALLOW_RUN_AS_ROOT_CONFIRM="1"

# ---- Build info for debugging ----
COPY --from=builder /tmp/nixl-sha.txt /opt/BUILD_INFO.nixl-sha
COPY --from=builder /tmp/uccl-sha.txt /opt/BUILD_INFO.uccl-sha

RUN echo "{\n\
  \"image_version\": \"${IMAGE_VERSION}\",\n\
  \"build_date\": \"${BUILD_DATE}\",\n\
  \"vcs_ref\": \"${VCS_REF}\",\n\
  \"efa_installer\": \"${EFA_INSTALLER_VERSION}\",\n\
  \"nixl_version\": \"${NIXL_VERSION}\",\n\
  \"uccl_ref\": \"${UCCL_REF}\",\n\
  \"sglang_version\": \"${SGLANG_VERSION}\"\n\
}" > /opt/BUILD_INFO.json

# ---- Sanity check ----
RUN python -c "import sglang; print('sglang OK', sglang.__version__)" && \
    python -c "import torch; print('torch OK', torch.__version__)" && \
    python -c "import nixl_cu13; print('nixl_cu13 OK', nixl_cu13.__file__)" && \
    python -c "import uccl.ep; print('uccl.ep OK')" && \
    python -c "import deep_ep; print('deep_ep OK')" && \
    /opt/amazon/efa/bin/fi_info --version

WORKDIR /workspace
CMD ["/bin/bash"]
