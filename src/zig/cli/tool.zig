//! ipmitool's C entry point, process globals and command table from src/ipmitool.c.

const c = @import("ipmi_c");
const Cmd = c.struct_ipmi_cmd;

pub export var csv_output: c_int = 0;
pub export var verbose: c_int = 0;

fn command(comptime handler: anytype, name: [*:0]const u8, desc: ?[*:0]const u8) Cmd {
    return .{ .func = @ptrCast(&handler), .name = name, .desc = desc };
}

const commands_before = [_]Cmd{
    command(c.ipmi_raw_main, "raw", "Send a RAW IPMI request and print response"),
    command(c.ipmi_rawi2c_main, "i2c", "Send an I2C Master Write-Read command and print response"),
    command(c.ipmi_rawspd_main, "spd", "Print SPD info from remote I2C device"),
    command(c.ipmi_lanp_main, "lan", "Configure LAN Channels"),
    command(c.ipmi_chassis_main, "chassis", "Get chassis status and set power state"),
    command(c.ipmi_power_main, "power", "Shortcut to chassis power commands"),
    command(c.ipmi_event_main, "event", "Send pre-defined events to MC"),
    command(c.ipmi_mc_main, "mc", "Management Controller status and global enables"),
    command(c.ipmi_mc_main, "bmc", null),
    command(c.ipmi_sdr_main, "sdr", "Print Sensor Data Repository entries and readings"),
    command(c.ipmi_sensor_main, "sensor", "Print detailed sensor information"),
    command(c.ipmi_fru_main, "fru", "Print built-in FRU and scan SDR for FRU locators"),
    command(c.ipmi_gendev_main, "gendev", "Read/Write Device associated with Generic Device locators sdr"),
    command(c.ipmi_sel_main, "sel", "Print System Event Log (SEL)"),
    command(c.ipmi_pef_main, "pef", "Configure Platform Event Filtering (PEF)"),
    command(c.ipmi_sol_main, "sol", "Configure and connect IPMIv2.0 Serial-over-LAN"),
    command(c.ipmi_tsol_main, "tsol", "Configure and connect with Tyan IPMIv1.5 Serial-over-LAN"),
    command(c.ipmi_isol_main, "isol", "Configure IPMIv1.5 Serial-over-LAN"),
    command(c.ipmi_user_main, "user", "Configure Management Controller users"),
    command(c.ipmi_channel_main, "channel", "Configure Management Controller channels"),
    command(c.ipmi_session_main, "session", "Print session information"),
    command(c.ipmi_dcmi_main, "dcmi", "Data Center Management Interface"),
    command(c.ipmi_nm_main, "nm", "Node Manager Interface"),
    command(c.ipmi_sunoem_main, "sunoem", "OEM Commands for Sun servers"),
    command(c.ipmi_kontronoem_main, "kontronoem", "OEM Commands for Kontron devices"),
    command(c.ipmi_picmg_main, "picmg", "Run a PICMG/ATCA extended cmd"),
    command(c.ipmi_fwum_main, "fwum", "Update IPMC using Kontron OEM Firmware Update Manager"),
    command(c.ipmi_firewall_main, "firewall", "Configure Firmware Firewall"),
    command(c.ipmi_delloem_main, "delloem", "OEM Commands for Dell systems"),
};

const shell_command = if (@hasDecl(c, "HAVE_READLINE"))
    [_]Cmd{command(c.ipmi_shell_main, "shell", "Launch interactive IPMI shell")}
else
    [_]Cmd{};

const commands_after = [_]Cmd{
    command(c.ipmi_exec_main, "exec", "Run list of commands from file"),
    command(c.ipmi_set_main, "set", "Set runtime variable for shell and exec"),
    command(c.ipmi_echo_main, "echo", null),
    command(c.ipmi_hpmfwupg_main, "hpm", "Update HPM components using PICMG HPM.1 file"),
    command(c.ipmi_ekanalyzer_main, "ekanalyzer", "run FRU-Ekeying analyzer using FRU files"),
    command(c.ipmi_ime_main, "ime", "Update Intel Manageability Engine Firmware"),
    command(c.ipmi_vita_main, "vita", "Run a VITA 46.11 extended cmd"),
    command(c.ipmi_lan6_main, "lan6", "Configure IPv6 LAN Channels"),
    .{ .func = null, .name = null, .desc = null },
};

pub export var ipmitool_cmd_list = commands_before ++ shell_command ++ commands_after;

pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    const rc = c.ipmi_main(argc, argv, @ptrCast(&ipmitool_cmd_list), null);
    return if (rc < 0) c.EXIT_FAILURE else c.EXIT_SUCCESS;
}
