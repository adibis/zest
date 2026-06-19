//! Public API surface for the zest library.
//!
//! This is the entry point consumers see when they write @import("zest").
//! All public types are re-exported here so callers never need to know
//! which internal file a type lives in.

const std = @import("std");

pub const App = @import("core/app.zig").App;
pub const Event = @import("core/app.zig").Event;
pub const UpdateResult = @import("core/app.zig").UpdateResult;
pub const RunOpts = @import("core/app.zig").RunOpts;
pub const FrameArena = @import("core/memory.zig").FrameArena;

pub const Anchor = @import("core/anchor.zig").Anchor;
pub const Horizontal = @import("core/anchor.zig").Horizontal;
pub const Vertical   = @import("core/anchor.zig").Vertical;

pub const Rect = @import("layout/rect.zig").Rect;
pub const Size = @import("layout/size.zig").Size;
pub const Direction = @import("layout/blueprint.zig").Direction;
pub const pane = @import("layout/blueprint.zig").pane;
pub const hsplit = @import("layout/blueprint.zig").hsplit;
pub const vsplit = @import("layout/blueprint.zig").vsplit;
pub const domain = @import("layout/blueprint.zig").domain;
pub const Layout = @import("widgets/box.zig").Layout;
pub const Text = @import("widgets/text.zig").Text;
pub const List        = @import("widgets/list.zig").List; // generic: List(C)
pub const DefaultList = List(Color);
pub const ProgressBar         = @import("widgets/progress.zig").ProgressBar;          // generic: ProgressBar(C)
pub const ProgressLabelOverlay = @import("widgets/progress.zig").LabelOverlay;        // generic: LabelOverlay(C)
pub const Gauge               = @import("widgets/gauge.zig").Gauge;                  // generic: Gauge(C)
pub const GaugeLabel          = @import("widgets/gauge.zig").Label;                  // generic: Label(C)
pub const Orientation         = @import("widgets/gauge.zig").Orientation;
pub const Spinner             = @import("widgets/spinner.zig").Spinner;              // generic: Spinner(C)
pub const spinner_frames      = @import("widgets/spinner.zig").frame_sets;
pub const Sparkline           = @import("widgets/sparkline.zig").Sparkline;          // generic: Sparkline(C)
pub const TitleBar            = @import("widgets/title_bar.zig").TitleBar;           // generic: TitleBar(C)
pub const TitleOpts           = @import("widgets/title_bar.zig").TitleOpts;          // generic: TitleOpts(C)
pub const TitleCaps           = @import("widgets/title_bar.zig").Caps;
pub const Table               = @import("widgets/table.zig").Table;                  // generic: Table(C)
pub const TableColumn         = @import("widgets/table.zig").Column;                 // generic: Column(C)
pub const TableAlignment      = @import("widgets/table.zig").Alignment;
pub const Tab                 = @import("widgets/tab.zig").Tab;                      // generic: Tab(C)
pub const PanelsType = @import("widgets/box.zig").PanelsType;
pub const Panel = @import("widgets/box.zig").Panel;
pub const Focus           = @import("core/focus.zig").Focus;
pub const FocusStack      = @import("core/focus.zig").FocusStack;
pub const DomainFocusType = @import("core/focus.zig").DomainFocusType;
pub const Color     = @import("core/theme.zig").Color;
pub const TextStyle = @import("core/theme.zig").TextStyle;
pub const Style     = @import("core/theme.zig").Style;       // generic: Style(C)
pub const Theme     = @import("core/theme.zig").Theme;       // generic: Theme(C)
pub const ByFocus   = @import("core/theme.zig").ByFocus;     // generic: ByFocus(T)
pub const ByState   = @import("core/theme.zig").ByState;     // generic: ByState(E, T)
pub const WidgetTheme      = @import("core/theme.zig").WidgetTheme;      // generic: WidgetTheme(C)
pub const catppuccin_mocha = @import("core/theme.zig").catppuccin_mocha; // Theme(Color), dark
pub const catppuccin_latte = @import("core/theme.zig").catppuccin_latte; // Theme(Color), light
pub const mocha_widget     = @import("core/theme.zig").mocha_widget;     // WidgetTheme(Color), dark
pub const latte_widget     = @import("core/theme.zig").latte_widget;     // WidgetTheme(Color), light
pub const DefaultStyle       = Style(Color);
pub const DefaultTheme       = Theme(Color);
pub const DefaultWidgetTheme = WidgetTheme(Color);

test {
    // Importing a file in a test block pulls its test blocks into the test
    // binary. Without these lines, tests in sub-files would compile but never
    // run when you execute `zig build test` against the root module.
    _ = @import("core/memory.zig");
    _ = @import("core/anchor.zig");
    _ = @import("core/app.zig");
    _ = @import("layout/rect.zig");
    _ = @import("layout/size.zig");
    _ = @import("layout/blueprint.zig");
    _ = @import("layout/solver.zig");
    _ = @import("widgets/box.zig");
    _ = @import("widgets/text.zig");
    _ = @import("widgets/list.zig");
    _ = @import("widgets/subcell.zig");
    _ = @import("widgets/progress.zig");
    _ = @import("widgets/gauge.zig");
    _ = @import("widgets/spinner.zig");
    _ = @import("widgets/sparkline.zig");
    _ = @import("widgets/title_bar.zig");
    _ = @import("widgets/table.zig");
    _ = @import("widgets/tab.zig");
    // Tutorial widget — kept in the test block so docs and code
    // stay in sync; intentionally not exported.
    _ = @import("widgets/example_toggle.zig");
    _ = @import("core/focus.zig");
    _ = @import("core/theme.zig");
}
