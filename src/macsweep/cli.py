"""CLI interface for MacSweep."""

import asyncio
from pathlib import Path

import typer
from rich.console import Console
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.table import Table

from macsweep import __version__
from macsweep.core.safety import SafetyChecker
from macsweep.utils.size import format_size, parse_size

app = typer.Typer(
    name="macsweep",
    help="MacSweep - A powerful macOS system cleaner",
    no_args_is_help=True,
    rich_markup_mode="rich",
)
console = Console()


def version_callback(value: bool) -> None:
    if value:
        console.print(f"[bold cyan]MacSweep[/bold cyan] v{__version__}")
        raise typer.Exit()


@app.callback()
def main(
    version: bool | None = typer.Option(
        None,
        "--version",
        "-v",
        callback=version_callback,
        is_eager=True,
        help="Show version and exit",
    ),
) -> None:
    """MacSweep - Clean, optimize, and monitor your Mac."""
    pass


@app.command()
def scan(
    category: str | None = typer.Option(
        None, "--category", "-c", help="Scan specific category only"
    ),
    json_output: bool = typer.Option(False, "--json", help="Output as JSON"),
) -> None:
    """Scan system for cleanup opportunities."""
    asyncio.run(_scan_async(category, json_output))


async def _scan_async(category: str | None, json_output: bool) -> None:
    """Async implementation of scan."""
    from macsweep.modules.browsers.brave import BraveModule
    from macsweep.modules.browsers.chrome import ChromeModule
    from macsweep.modules.browsers.safari import SafariModule
    from macsweep.modules.service_workers import ServiceWorkerModule
    from macsweep.modules.system.caches import SystemCachesModule

    modules = [
        ServiceWorkerModule(),
        SystemCachesModule(),
        BraveModule(),
        ChromeModule(),
        SafariModule(),
    ]

    if category:
        modules = [m for m in modules if m.category.lower() == category.lower()]

    results = []
    total_size = 0

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        for module in modules:
            task = progress.add_task(f"Scanning {module.name}...", total=None)
            result = await module.get_scan_result()
            results.append(result)
            total_size += result.total_size
            progress.remove_task(task)

    if json_output:
        import json

        data = {
            "total_size": total_size,
            "total_size_formatted": format_size(total_size),
            "modules": [
                {
                    "name": r.module_name,
                    "items": len(r.items),
                    "size": r.total_size,
                    "size_formatted": format_size(r.total_size),
                    "error": r.error,
                }
                for r in results
            ],
        }
        console.print_json(json.dumps(data))
        return

    # Display results table
    table = Table(title="Scan Results", show_header=True)
    table.add_column("Category", style="cyan")
    table.add_column("Items", justify="right")
    table.add_column("Size", justify="right", style="green")
    table.add_column("Status", style="yellow")

    for result in results:
        status = "Ready" if not result.error else f"[red]{result.error}[/red]"
        table.add_row(
            result.module_name,
            str(len(result.items)),
            format_size(result.total_size),
            status,
        )

    table.add_section()
    table.add_row("[bold]Total[/bold]", "", f"[bold]{format_size(total_size)}[/bold]", "")

    console.print(table)
    console.print("\n[dim]Run [bold]macsweep clean[/bold] to remove these items[/dim]")


@app.command()
def clean(
    dry_run: bool = typer.Option(True, "--dry-run/--execute", help="Preview changes or execute"),
    category: str | None = typer.Option(
        None, "--category", "-c", help="Clean specific category only"
    ),
    force: bool = typer.Option(False, "--force", "-f", help="Skip confirmations"),
) -> None:
    """Clean up selected items."""
    asyncio.run(_clean_async(dry_run, category, force))


async def _clean_async(dry_run: bool, category: str | None, force: bool) -> None:
    """Async implementation of clean."""
    from macsweep.modules.service_workers import ServiceWorkerModule
    from macsweep.modules.system.caches import SystemCachesModule

    modules = [
        ServiceWorkerModule(),
        SystemCachesModule(),
    ]

    if category:
        modules = [m for m in modules if m.category.lower() == category.lower()]

    all_items = []
    for module in modules:
        async for item in module.scan():
            all_items.append(item)

    if not all_items:
        console.print("[yellow]No items found to clean.[/yellow]")
        return

    safety = SafetyChecker()

    # Validate all items
    validation = safety.validate_batch([item.path for item in all_items])
    safe_items = [item for item in all_items if item.path in validation["safe"]]
    safe_items_sorted = sorted(safe_items, key=lambda x: x.size, reverse=True)
    safe_total_size = sum(item.size for item in safe_items)

    if validation["blocked"]:
        console.print(f"[yellow]{len(validation['blocked'])} items blocked for safety[/yellow]")

    if dry_run:
        console.print(Panel("[bold yellow]DRY RUN[/bold yellow] - No files will be deleted"))

        table = Table(title="Items to be cleaned")
        table.add_column("Path", style="cyan", max_width=60)
        table.add_column("Size", justify="right", style="green")
        table.add_column("Category", style="yellow")

        for item in safe_items_sorted:
            table.add_row(
                str(item.path).replace(str(Path.home()), "~"),
                format_size(item.size),
                item.subcategory,
            )

        console.print(table)
        console.print(f"\n[bold]Total: {format_size(safe_total_size)}[/bold]")
        console.print("\n[dim]Run with [bold]--execute[/bold] to delete[/dim]")
        return

    # Actual deletion
    if not force:
        confirm = typer.confirm(f"Delete {len(safe_items)} items ({format_size(safe_total_size)})?")
        if not confirm:
            console.print("[yellow]Cancelled.[/yellow]")
            return

    bytes_freed = 0
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        task = progress.add_task("Cleaning...", total=len(safe_items))
        for item in safe_items:
            try:
                if item.path.is_dir():
                    import shutil

                    bytes_freed += item.size
                    shutil.rmtree(item.path, ignore_errors=True)
                elif item.path.exists():
                    bytes_freed += item.path.stat().st_size
                    item.path.unlink()
            except (PermissionError, OSError):
                pass
            progress.advance(task)

    console.print(f"\n[bold green]Cleaned {format_size(bytes_freed)}[/bold green]")


@app.command("service-workers")
def service_workers(
    dry_run: bool = typer.Option(True, "--dry-run/--execute", help="Preview or execute"),
) -> None:
    """Delete all browser service workers."""
    asyncio.run(_service_workers_async(dry_run))


async def _service_workers_async(dry_run: bool) -> None:
    """Async implementation of service-workers command."""
    from macsweep.modules.service_workers import ServiceWorkerModule

    module = ServiceWorkerModule()
    result = await module.get_scan_result()

    if not result.items:
        console.print("[yellow]No service workers found.[/yellow]")
        return

    console.print(Panel(f"[bold]Found {len(result.items)} service worker locations[/bold]"))

    table = Table(title="Service Workers")
    table.add_column("Application", style="cyan")
    table.add_column("Path", style="dim", max_width=50)
    table.add_column("Size", justify="right", style="green")

    for item in result.items:
        table.add_row(
            item.subcategory,
            str(item.path).replace(str(Path.home()), "~"),
            format_size(item.size),
        )

    console.print(table)
    console.print(f"\n[bold]Total: {format_size(result.total_size)}[/bold]")

    if dry_run:
        console.print("\n[dim]Run with [bold]--execute[/bold] to delete[/dim]")
        return

    confirm = typer.confirm("Delete all service workers?")
    if not confirm:
        console.print("[yellow]Cancelled.[/yellow]")
        return

    bytes_freed = await module.clean(result.items, dry_run=False)
    console.print(f"\n[bold green]Freed {format_size(bytes_freed)}[/bold green]")


@app.command("large-files")
def large_files(
    min_size: str = typer.Option("100MB", "--min-size", "-s", help="Minimum file size"),
    path: str = typer.Option("~", "--path", "-p", help="Path to scan"),
    limit: int = typer.Option(50, "--limit", "-n", help="Max files to show"),
) -> None:
    """Find large files."""
    asyncio.run(_large_files_async(min_size, path, limit))


async def _large_files_async(min_size: str, path: str, limit: int) -> None:
    """Async implementation of large-files command."""
    from macsweep.analyzers.large_files import LargeFileFinder

    min_bytes = parse_size(min_size)
    scan_path = Path(path).expanduser()

    finder = LargeFileFinder(min_size_bytes=min_bytes)

    console.print(f"Scanning [cyan]{scan_path}[/cyan] for files > {min_size}...")

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        task = progress.add_task("Scanning...", total=None)
        files = await finder.find(scan_path, limit=limit)
        progress.remove_task(task)

    if not files:
        console.print(f"[yellow]No files larger than {min_size} found.[/yellow]")
        return

    table = Table(title=f"Large Files (>{min_size})")
    table.add_column("#", style="dim")
    table.add_column("Path", style="cyan", max_width=60)
    table.add_column("Size", justify="right", style="green")
    table.add_column("Modified", style="yellow")

    for i, (file_path, size, modified) in enumerate(files, 1):
        table.add_row(
            str(i),
            str(file_path).replace(str(Path.home()), "~"),
            format_size(size),
            modified.strftime("%Y-%m-%d"),
        )

    console.print(table)
    total = sum(size for _, size, _ in files)
    console.print(f"\n[bold]Total: {format_size(total)} across {len(files)} files[/bold]")


@app.command("unused-apps")
def unused_apps(
    days: int = typer.Option(90, "--days", "-d", help="Days since last use"),
) -> None:
    """Find applications not used recently."""
    asyncio.run(_unused_apps_async(days))


async def _unused_apps_async(days: int) -> None:
    """Async implementation of unused-apps command."""
    from macsweep.analyzers.unused_apps import UnusedAppsAnalyzer

    analyzer = UnusedAppsAnalyzer(days_threshold=days)

    console.print(f"Finding apps not used in {days} days...")

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        task = progress.add_task("Analyzing...", total=None)
        apps = await analyzer.find_unused_apps()
        progress.remove_task(task)

    if not apps:
        console.print(f"[green]All apps have been used within {days} days![/green]")
        return

    table = Table(title=f"Apps Not Used in {days}+ Days")
    table.add_column("Application", style="cyan")
    table.add_column("Size", justify="right", style="green")
    table.add_column("Last Used", style="yellow")
    table.add_column("Days Ago", justify="right")

    for app in apps[:20]:
        last_used = app.last_used.strftime("%Y-%m-%d") if app.last_used else "Never"
        days_ago = str(app.days_since_use) if app.days_since_use else "N/A"
        table.add_row(app.name, format_size(app.size), last_used, days_ago)

    if len(apps) > 20:
        table.add_row("...", "", "", f"+{len(apps) - 20} more")

    console.print(table)
    total = sum(app.size for app in apps)
    console.print(f"\n[bold]Total: {format_size(total)} across {len(apps)} apps[/bold]")
    console.print(
        "\n[dim]Note: MacSweep won't auto-delete apps. Review and uninstall manually.[/dim]"
    )


@app.command()
def monitor() -> None:
    """Launch real-time system monitor."""
    asyncio.run(_monitor_async())


async def _monitor_async() -> None:
    """Async implementation of monitor command."""
    from macsweep.monitors.cpu import CPUMonitor
    from macsweep.monitors.memory import MemoryMonitor

    mem_monitor = MemoryMonitor()
    cpu_monitor = CPUMonitor()

    console.print("[bold]System Monitor[/bold] (Ctrl+C to exit)\n")

    try:
        while True:
            mem = mem_monitor.get_stats()
            cpu = cpu_monitor.get_stats()

            # Clear previous output
            console.print("\033[2J\033[H", end="")
            console.print("[bold cyan]MacSweep System Monitor[/bold cyan]\n")

            # Memory
            mem_bar = "█" * int(mem.used_percent / 5) + "░" * (20 - int(mem.used_percent / 5))
            console.print(f"[bold]Memory:[/bold] {mem_bar} {mem.used_percent:.1f}%")
            console.print(f"  Used: {format_size(mem.used_bytes)} / {format_size(mem.total_bytes)}")
            console.print(f"  Pressure: {mem.pressure}")

            # CPU
            cpu_bar = "█" * int(cpu.usage_percent / 5) + "░" * (20 - int(cpu.usage_percent / 5))
            console.print(f"\n[bold]CPU:[/bold]    {cpu_bar} {cpu.usage_percent:.1f}%")

            console.print("\n[dim]Press Ctrl+C to exit[/dim]")

            await asyncio.sleep(1)
    except KeyboardInterrupt:
        console.print("\n[yellow]Monitor stopped.[/yellow]")


@app.command()
def tui() -> None:
    """Launch interactive TUI."""
    try:
        from macsweep.tui.app import MacSweepApp

        app = MacSweepApp()
        app.run()
    except ImportError:
        console.print("[red]TUI requires textual. Install with: pip install textual[/red]")


if __name__ == "__main__":
    app()
