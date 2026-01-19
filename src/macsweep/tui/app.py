"""Main TUI application for MacSweep."""

from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Center, Container, Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import (
    Button,
    Checkbox,
    DataTable,
    Footer,
    Header,
    Label,
    LoadingIndicator,
    ProgressBar,
    Static,
)

from macsweep import __version__
from macsweep.utils.size import format_size


class ConfirmDeleteScreen(ModalScreen[bool]):
    """Modal screen to confirm deletion."""

    BINDINGS = [
        ("escape", "cancel", "Cancel"),
        ("enter", "confirm", "Confirm"),
    ]

    CSS = """
    ConfirmDeleteScreen {
        align: center middle;
    }

    #confirm-dialog {
        width: 50;
        height: 18;
        border: thick #f7768e;
        background: #24283b;
        padding: 2;
    }

    #confirm-title {
        text-style: bold;
        color: #f7768e;
        text-align: center;
        width: 100%;
        padding: 1;
    }

    #confirm-message {
        text-align: center;
        padding: 1;
        color: #a9b1d6;
    }

    #confirm-warning {
        text-align: center;
        color: #e0af68;
        padding: 1;
        text-style: italic;
    }

    #confirm-hint {
        text-align: center;
        color: #9ece6a;
        padding: 1;
        margin-top: 2;
        text-style: bold;
        border: round #3b4261;
    }
    """

    def __init__(self, item_count: int, total_size: str) -> None:
        super().__init__()
        self.item_count = item_count
        self.total_size = total_size

    def compose(self) -> ComposeResult:
        with Container(id="confirm-dialog"):
            yield Label("Confirm Deletion", id="confirm-title")
            yield Label(
                f"Delete {self.item_count} items ({self.total_size})?",
                id="confirm-message",
            )
            yield Label("This action cannot be undone!", id="confirm-warning")
            yield Label("[Enter] Delete  |  [Esc] Cancel", id="confirm-hint")

    def action_cancel(self) -> None:
        self.dismiss(False)

    def action_confirm(self) -> None:
        self.dismiss(True)


class LoadingOverlay(Static):
    """Full-screen loading overlay with spinner."""

    CSS = """
    LoadingOverlay {
        width: 100%;
        height: 100%;
        background: $surface 80%;
        align: center middle;
        display: none;
    }

    LoadingOverlay.visible {
        display: block;
    }

    #loading-box {
        width: 40;
        height: 9;
        background: $panel;
        border: round $primary;
        align: center middle;
    }

    #loading-text {
        text-align: center;
        color: $primary;
        text-style: bold;
        padding: 1;
    }

    #loading-subtext {
        text-align: center;
        color: $text-muted;
        padding-bottom: 1;
    }
    """

    def __init__(self) -> None:
        super().__init__()
        self._message = "Loading..."
        self._subtext = ""

    def compose(self) -> ComposeResult:
        with Center(id="loading-box"):
            yield LoadingIndicator()
            yield Label(self._message, id="loading-text")
            yield Label(self._subtext, id="loading-subtext")

    def show(self, message: str = "Loading...", subtext: str = "") -> None:
        self.query_one("#loading-text", Label).update(message)
        self.query_one("#loading-subtext", Label).update(subtext)
        self.add_class("visible")

    def hide(self) -> None:
        self.remove_class("visible")

    def update_subtext(self, subtext: str) -> None:
        self.query_one("#loading-subtext", Label).update(subtext)


class SystemHealthWidget(Static):
    """Widget showing system health metrics."""

    def compose(self) -> ComposeResult:
        yield Label("System Health", classes="widget-title")
        yield Horizontal(
            Label("CPU:", classes="metric-label"),
            ProgressBar(total=100, show_percentage=True, id="cpu-bar"),
            classes="metric-row",
        )
        yield Horizontal(
            Label("RAM:", classes="metric-label"),
            ProgressBar(total=100, show_percentage=True, id="ram-bar"),
            classes="metric-row",
        )
        yield Horizontal(
            Label("Disk:", classes="metric-label"),
            ProgressBar(total=100, show_percentage=True, id="disk-bar"),
            classes="metric-row",
        )

    def update_stats(self, cpu: float, ram: float, disk: float) -> None:
        self.query_one("#cpu-bar", ProgressBar).update(progress=cpu)
        self.query_one("#ram-bar", ProgressBar).update(progress=ram)
        self.query_one("#disk-bar", ProgressBar).update(progress=disk)


class MacSweepApp(App):
    """Main TUI application."""

    CSS = """
    Screen {
        background: #1a1b26;
    }

    Header {
        background: #7aa2f7;
        color: #1a1b26;
    }

    Footer {
        background: #24283b;
    }

    .widget-title {
        text-style: bold;
        padding: 1;
        color: #7aa2f7;
        border-bottom: solid #3b4261;
    }

    .main-layout {
        height: 100%;
    }

    .left-panel {
        width: 34;
        padding: 1;
        background: #24283b;
        border-right: solid #3b4261;
    }

    .right-panel {
        width: 1fr;
        padding: 1;
    }

    .metric-row {
        height: 3;
        padding: 0 1;
    }

    .metric-label {
        width: 6;
        color: #a9b1d6;
    }

    .metric-row ProgressBar {
        width: 1fr;
    }

    ProgressBar > .bar--bar {
        color: #7aa2f7;
    }

    ProgressBar > .bar--complete {
        color: #9ece6a;
    }

    Button {
        width: 100%;
        margin: 1 0;
        border: tall transparent;
    }

    Button:hover {
        border: tall $accent;
    }

    #btn-scan {
        background: #7aa2f7;
        color: #1a1b26;
    }

    #btn-scan:hover {
        background: #89b4fa;
    }

    #btn-delete {
        background: #f7768e;
        color: #1a1b26;
    }

    #btn-delete:hover {
        background: #ff9e9e;
    }

    #btn-delete:disabled {
        background: #3b4261;
        color: #565f89;
    }

    #scan-table {
        height: 1fr;
        margin: 1 0;
        background: #24283b;
        border: round #3b4261;
    }

    DataTable > .datatable--header {
        background: #3b4261;
        color: #7aa2f7;
        text-style: bold;
    }

    DataTable > .datatable--cursor {
        background: #3b4261;
    }

    DataTable > .datatable--hover {
        background: #292e42;
    }

    #status-bar {
        height: 3;
        padding: 1;
        background: #24283b;
        border: round #3b4261;
    }

    #selection-info {
        color: #a9b1d6;
    }

    #total-size {
        color: #9ece6a;
        text-style: bold;
        padding: 1;
        height: 5;
        text-align: center;
        background: #1a1b26;
        border: round #3b4261;
        margin: 1 0;
    }

    #size-filter {
        margin: 1 0;
        padding: 0 1;
        color: #a9b1d6;
    }

    SystemHealthWidget {
        margin-top: 1;
        padding: 1;
        background: #1a1b26;
        border: round #3b4261;
    }
    """

    TITLE = "MacSweep"
    SUB_TITLE = f"v{__version__}"

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("s", "scan", "Scan"),
        Binding("space", "toggle_selection", "Toggle", show=True),
        Binding("a", "select_all", "Select All"),
        Binding("n", "select_none", "Clear"),
        Binding("d", "delete_selected", "Delete"),
        Binding("r", "refresh", "Refresh"),
    ]

    # Minimum size to display (100MB default)
    MIN_SIZE_BYTES = 100 * 1024 * 1024

    def __init__(self) -> None:
        super().__init__()
        self._update_timer = None
        self._all_scanned_items: list = []  # Unfiltered
        self._scanned_items: list = []  # Filtered for display
        self._selected_rows: set = set()
        self._is_scanning = False
        self._size_filter_enabled = True

    def compose(self) -> ComposeResult:
        yield Header()
        yield Horizontal(
            Vertical(
                Label("Actions", classes="widget-title"),
                Button("Scan System", id="btn-scan", variant="primary"),
                Button("Delete Selected", id="btn-delete", variant="error", disabled=True),
                Static("", id="total-size"),
                Checkbox(">100MB only", value=True, id="size-filter"),
                SystemHealthWidget(),
                classes="left-panel",
            ),
            Vertical(
                Label("Scan Results", classes="widget-title"),
                DataTable(id="scan-table", cursor_type="row", zebra_stripes=True),
                Horizontal(
                    Label("Press [S] to scan for junk files", id="selection-info"),
                    id="status-bar",
                ),
                classes="right-panel",
            ),
            classes="main-layout",
        )
        yield LoadingOverlay()
        yield Footer()

    def on_mount(self) -> None:
        self._update_timer = self.set_interval(2, self._update_system_stats)
        self._update_system_stats()

        table = self.query_one("#scan-table", DataTable)
        table.add_column("", key="selected", width=3)
        table.add_column("Path", key="path", width=55)
        table.add_column("Size", key="size", width=10)
        table.add_column("Type", key="category", width=18)

    def _update_system_stats(self) -> None:
        try:
            from macsweep.monitors.cpu import CPUMonitor
            from macsweep.monitors.memory import MemoryMonitor

            mem = MemoryMonitor().get_stats()
            cpu = CPUMonitor().get_stats()

            import shutil

            disk = shutil.disk_usage("/")
            disk_percent = (disk.used / disk.total) * 100

            health_widget = self.query_one(SystemHealthWidget)
            health_widget.update_stats(
                cpu=cpu.usage_percent,
                ram=mem.used_percent,
                disk=disk_percent,
            )
        except Exception:
            pass

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-scan":
            self.action_scan()
        elif event.button.id == "btn-delete":
            self.action_delete_selected()

    def action_scan(self) -> None:
        if self._is_scanning:
            return
        self._is_scanning = True
        self.query_one("#btn-scan", Button).disabled = True
        self.query_one(LoadingOverlay).show("Scanning...", "Initializing...")
        # Run in thread because scanning uses blocking subprocess calls
        self.run_worker(self._run_scan(), thread=True)

    async def _run_scan(self) -> None:
        from macsweep.core.safety import SafetyChecker
        from macsweep.modules.browsers.brave import BraveModule
        from macsweep.modules.dev import NodeModulesModule
        from macsweep.modules.service_workers import ServiceWorkerModule
        from macsweep.modules.system.caches import SystemCachesModule

        modules = [
            ("Node Modules", NodeModulesModule()),
            ("Brave Browser", BraveModule()),
            ("Service Workers", ServiceWorkerModule()),
            ("System Caches", SystemCachesModule()),
        ]
        all_items = []

        for name, module in modules:
            self.call_from_thread(
                self.query_one(LoadingOverlay).update_subtext,
                f"Scanning {name}...",
            )
            async for item in module.scan():
                all_items.append(item)

        self.call_from_thread(
            self.query_one(LoadingOverlay).update_subtext,
            "Validating paths...",
        )

        safety = SafetyChecker()
        validation = safety.validate_batch([item.path for item in all_items])
        safe_items = [item for item in all_items if item.path in validation["safe"]]
        safe_items.sort(key=lambda x: x.size, reverse=True)

        # Store all items unfiltered
        self._all_scanned_items = safe_items
        self._selected_rows = set()

        self.call_from_thread(self._finish_scan)

    def _apply_size_filter(self) -> None:
        """Apply size filter to scanned items."""
        if self._size_filter_enabled:
            self._scanned_items = [
                item for item in self._all_scanned_items if item.size >= self.MIN_SIZE_BYTES
            ]
        else:
            self._scanned_items = list(self._all_scanned_items)

    def _finish_scan(self) -> None:
        """Finish scan and update UI on main thread."""
        self._apply_size_filter()
        self._populate_table()
        self.query_one(LoadingOverlay).hide()
        self._is_scanning = False
        self.query_one("#btn-scan", Button).disabled = False

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        """Handle checkbox state changes."""
        if event.checkbox.id == "size-filter":
            self._size_filter_enabled = event.value
            self._selected_rows = set()
            self._apply_size_filter()
            self._populate_table()

    def _populate_table(self) -> None:
        table = self.query_one("#scan-table", DataTable)
        table.clear()

        total_size = sum(item.size for item in self._scanned_items)

        for idx, item in enumerate(self._scanned_items):
            path_str = str(item.path).replace(str(Path.home()), "~")
            if len(path_str) > 52:
                path_str = "..." + path_str[-49:]
            table.add_row(
                "☐",
                path_str,
                format_size(item.size),
                item.subcategory,
                key=str(idx),
            )

        self.query_one("#total-size", Static).update(
            f"Total: {format_size(total_size)}\n{len(self._scanned_items)} items"
        )
        self._update_selection_info()
        self.notify(f"Found {len(self._scanned_items)} items", severity="information")

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        self._toggle_row(event.row_key)

    def action_toggle_selection(self) -> None:
        table = self.query_one("#scan-table", DataTable)
        if table.cursor_row is not None and table.row_count > 0:
            self._toggle_row(str(table.cursor_row))

    def _toggle_row(self, row_key) -> None:
        table = self.query_one("#scan-table", DataTable)
        key_str = str(row_key.value) if hasattr(row_key, "value") else str(row_key)

        if key_str in self._selected_rows:
            self._selected_rows.discard(key_str)
            table.update_cell(row_key, "selected", "☐")
        else:
            self._selected_rows.add(key_str)
            table.update_cell(row_key, "selected", "☑")

        self._update_selection_info()

    def action_select_all(self) -> None:
        table = self.query_one("#scan-table", DataTable)
        self._selected_rows = set()

        for idx in range(len(self._scanned_items)):
            key_str = str(idx)
            self._selected_rows.add(key_str)
            table.update_cell(key_str, "selected", "☑")

        self._update_selection_info()

    def action_select_none(self) -> None:
        table = self.query_one("#scan-table", DataTable)

        for key_str in list(self._selected_rows):
            table.update_cell(key_str, "selected", "☐")

        self._selected_rows = set()
        self._update_selection_info()

    def _update_selection_info(self) -> None:
        label = self.query_one("#selection-info", Label)
        btn = self.query_one("#btn-delete", Button)

        if not self._selected_rows:
            label.update("Select items with [Space] and press [D] to delete")
            btn.disabled = True
        else:
            selected_size = sum(
                self._scanned_items[int(idx)].size
                for idx in self._selected_rows
                if int(idx) < len(self._scanned_items)
            )
            label.update(
                f"{len(self._selected_rows)} selected -> Will free {format_size(selected_size)}"
            )
            btn.disabled = False

    def action_delete_selected(self) -> None:
        if not self._selected_rows:
            self.notify("No items selected", severity="warning")
            return

        selected_size = sum(
            self._scanned_items[int(idx)].size
            for idx in self._selected_rows
            if int(idx) < len(self._scanned_items)
        )

        self.push_screen(
            ConfirmDeleteScreen(len(self._selected_rows), format_size(selected_size)),
            self._on_confirm_delete,
        )

    def _on_confirm_delete(self, confirmed: bool) -> None:
        if confirmed:
            self.query_one(LoadingOverlay).show("Deleting...", "Please wait...")
            # Run in thread because shutil.rmtree is blocking I/O
            self.run_worker(self._delete_items(), thread=True)

    async def _delete_items(self) -> None:
        import shutil

        bytes_freed = 0
        items_deleted = 0

        for idx_str in list(self._selected_rows):
            idx = int(idx_str)
            if idx >= len(self._scanned_items):
                continue

            item = self._scanned_items[idx]
            self.call_from_thread(
                self.query_one(LoadingOverlay).update_subtext,
                f"Removing {item.path.name}...",
            )

            try:
                if item.path.is_dir():
                    bytes_freed += item.size
                    shutil.rmtree(item.path, ignore_errors=True)
                    items_deleted += 1
                elif item.path.exists():
                    bytes_freed += item.path.stat().st_size
                    item.path.unlink()
                    items_deleted += 1
            except (PermissionError, OSError):
                pass

        self.call_from_thread(
            self.notify,
            f"Deleted {items_deleted} items, freed {format_size(bytes_freed)}",
            severity="information",
        )

        # Rescan on main thread
        self.call_from_thread(self._trigger_rescan)

    def _trigger_rescan(self) -> None:
        """Trigger a rescan after deletion."""
        self.run_worker(self._run_scan())

    def action_refresh(self) -> None:
        self._update_system_stats()
        self.notify("Refreshed", severity="information")


def main() -> None:
    app = MacSweepApp()
    app.run()


if __name__ == "__main__":
    main()
