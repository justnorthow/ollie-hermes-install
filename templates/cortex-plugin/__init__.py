from .provider import CortexProvider


def register(ctx):
    ctx.register_memory_provider(CortexProvider())
