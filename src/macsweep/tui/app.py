"""Main TUI application for MacSweep."""

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import (
    Button,
    Footer,
    Header,
    Label,
    ProgressBar,
    Static,
    TabbedContent,
    TabPane,
)

from macsweep import __version__


class SystemHealthWidget(Static):
    """Widget showing system health metrics."""

    def compose(self) -> ComposeResult:
        yield Label("System Health", classes="widget-title")
        yield Horizontal(
            Label("CPU:"),
            ProgressBar(total=100, show_percentage=True, id="cpu-bar"),
            classes="metric-row",
        )
        yield Horizontal(
            Label("RAM:"),
            ProgressBar(total=100, show_percentage=True, id="ram-bar"),
            classes="metric-row",
        )
        yield Horizontal(
            Label("Disk:"),
            ProgressBar(total=100, show_percentage=True, id="disk-bar"),
            classes="metric-row",
        )

    def update_stats(self, cpu: float, ram: float, disk: float) -> None:
        """Update the progress bars with current stats."""
        cpu_bar = self.query_one("#cpu-bar", ProgressBar)
        ram_bar = self.query_one("#ram-bar", ProgressBar)
        disk_bar = self.query_one("#disk-bar", ProgressBar)

        cpu_bar.update(progress=cpu)
        ram_bar.update(progress=ram)
        disk_bar.update(progress=disk)


class QuickActionsWidget(Static):
    """Widget with quick action buttons."""

    def compose(self) -> ComposeResult:
        yield Label("Quick Actions", classes="widget-title")
        yield Button("Scan All", id="btn-scan", variant="primary")
        yield Button("Clean Service Workers", id="btn-sw")
        yield Button("Empty Trash", id="btn-trash")
        yield Button("Find Large Files", id="btn-large")


class ScanResultsWidget(Static):
    """Widget showing scan results."""

    def compose(self) -> ComposeResult:
        yield Label("Scan Results", classes="widget-title")
        yield Static("Run a scan to see results here.", id="scan-results")


class DashboardScreen(Static):
    """Main dashboard screen."""

    def compose(self) -> ComposeResult:
        yield Horizontal(
            Vertical(
                QuickActionsWidget(),
                classes="left-panel",
            ),
            Vertical(
                SystemHealthWidget(),
                ScanResultsWidget(),
                classes="right-panel",
            ),
            classes="dashboard-layout",
        )


class MacSweepApp(App):
    """Main TUI application."""

    CSS = """
    Screen {
        background: $surface;
    }

    .widget-title {
        text-style: bold;
        padding: 1;
        color: $primary;
    }

    .dashboard-layout {
        height: 100%;
    }

    .left-panel {
        width: 30;
        padding: 1;
        border-right: solid $primary;
    }

    .right-panel {
        width: 1fr;
        padding: 1;
    }

    .metric-row {
        height: 3;
        padding: 0 1;
    }

    .metric-row Label {
        width: 6;
    }

    .metric-row ProgressBar {
        width: 1fr;
    }

    Button {
        width: 100%;
        margin: 1 0;
    }

    #scan-results {
        height: 1fr;
        padding: 1;
        border: solid $primary;
    }

    TabbedContent {
        height: 100%;
    }

    TabPane {
        padding: 1;
    }
    """

    TITLE = "MacSweep"
    SUB_TITLE = f"v{__version__}"

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("d", "switch_tab('dashboard')", "Dashboard", show=False),
        Binding("s", "scan", "Scan"),
        Binding("?", "help", "Help"),
        Binding("r", "refresh", "Refresh"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._update_timer = None

    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent():
            with TabPane("Dashboard", id="dashboard"):
                yield DashboardScreen()
            with TabPane("Scan Results", id="scan"):
                yield Static("Scan results will appear here after running a scan.")
            with TabPane("Large Files", id="large-files"):
                yield Static("Large files will be listed here.")
            with TabPane("Unused Apps", id="unused-apps"):
                yield Static("Unused applications will be listed here.")
            with TabPane("Monitor", id="monitor"):
                yield Static("Real-time system monitoring.")
        yield Footer()

    def on_mount(self) -> None:
        """Start periodic updates when app mounts."""
        self._update_timer = self.set_interval(2, self._update_system_stats)
        # Initial update
        self._update_system_stats()

    def _update_system_stats(self) -> None:
        """Update system health statistics."""
        try:
            from macsweep.monitors.cpu import CPUMonitor
            from macsweep.monitors.memory import MemoryMonitor

            mem = MemoryMonitor().get_stats()
            cpu = CPUMonitor().get_stats()

            # Get disk usage
            import shutil

            disk = shutil.disk_usage("/")
            disk_percent = (disk.used / disk.total) * 100

            # Update widget
            health_widget = self.query_one(SystemHealthWidget)
            health_widget.update_stats(
                cpu=cpu.usage_percent,
                ram=mem.used_percent,
                disk=disk_percent,
            )
        except Exception:
            pass

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button presses."""
        button_id = event.button.id

        if button_id == "btn-scan":
            self.action_scan()
        elif button_id == "btn-sw":
            self._clean_service_workers()
        elif button_id == "btn-trash":
            self._empty_trash()
        elif button_id == "btn-large":
            self._find_large_files()

    def action_scan(self) -> None:
        """Run a full system scan."""
        self.notify("Starting scan...", severity="information")
        # Run scan in background
        self.run_worker(self._run_scan())

    async def _run_scan(self) -> None:
        """Run the scan operation."""
        from macsweep.modules.service_workers import ServiceWorkerModule
        from macsweep.modules.system.caches import SystemCachesModule
        from macsweep.utils.size import format_size

        modules = [ServiceWorkerModule(), SystemCachesModule()]
        total_size = 0
        total_items = 0

        for module in modules:
            result = await module.get_scan_result()
            total_size += result.total_size
            total_items += len(result.items)

        self.notify(
            f"Found {total_items} items ({format_size(total_size)})",
            severity="information",
        )

    def _clean_service_workers(self) -> None:
        """Clean service workers."""
        self.notify("Use CLI: macsweep service-workers --execute", severity="warning")

    def _empty_trash(self) -> None:
        """Empty the trash."""
        self.notify("Use CLI: macsweep clean --category system --execute", severity="warning")

    def _find_large_files(self) -> None:
        """Find large files."""
        self.notify("Use CLI: macsweep large-files", severity="information")

    def action_switch_tab(self, tab_id: str) -> None:
        """Switch to a specific tab."""
        tabbed = self.query_one(TabbedContent)
        tabbed.active = tab_id

    def action_help(self) -> None:
        """Show help."""
        self.notify(
            "Press 's' to scan, 'q' to quit. Use CLI for more options.",
            severity="information",
        )

    def action_refresh(self) -> None:
        """Refresh system stats."""
        self._update_system_stats()
        self.notify("Refreshed", severity="information")


def main() -> None:
    """Run the TUI application."""
    app = MacSweepApp()
    app.run()


if __name__ == "__main__":
    main()
