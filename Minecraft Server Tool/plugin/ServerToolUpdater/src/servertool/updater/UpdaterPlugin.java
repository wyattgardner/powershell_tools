package servertool.updater;

import org.bukkit.ChatColor;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.plugin.java.JavaPlugin;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.time.Instant;
import java.util.concurrent.TimeUnit;

/**
 * /update and /update confirm.
 *
 * The plugin does no updating itself. It starts a Windows scheduled task that runs
 * update-spigot.ps1 for this server. That indirection is the point: the update has
 * to stop this server, and NSSM kills the server's whole process tree when the
 * service stops, so anything launched from inside the JVM would die halfway. A
 * scheduled task runs outside that tree. The server runs as LocalSystem, which is
 * allowed to start any task.
 *
 * /update confirm also drops update.force in the server folder, which the script
 * reads once as -Force (permission to jump Minecraft versions).
 *
 * Progress messages come from the script over RCON, not from here.
 */
public final class UpdaterPlugin extends JavaPlugin {

    private long lastRun = 0;

    @Override
    public void onEnable() {
        saveDefaultConfig();
        String task = getConfig().getString("task-name", "");
        if (task.isEmpty()) {
            getLogger().warning("task-name is empty in config.yml; /update won't work until it's set.");
        } else {
            getLogger().info("/update runs scheduled task: " + task);
        }
    }

    @Override
    public boolean onCommand(CommandSender sender, Command command, String label, String[] args) {
        String task = getConfig().getString("task-name", "");
        if (task.isEmpty()) {
            sender.sendMessage(ChatColor.RED + "Updater isn't configured (task-name missing in config.yml).");
            return true;
        }

        boolean confirm = args.length > 0 && args[0].equalsIgnoreCase("confirm");
        if (args.length > 0 && !confirm) return false;   // prints usage

        long now = System.currentTimeMillis();
        long cooldownMs = getConfig().getInt("cooldown-seconds", 60) * 1000L;
        if (now - lastRun < cooldownMs) {
            sender.sendMessage(ChatColor.YELLOW + "An update was started " + ((now - lastRun) / 1000)
                    + "s ago. Give it a minute.");
            return true;
        }

        if (confirm) {
            try {
                File flag = new File(getServer().getWorldContainer(), "update.force");
                Files.write(flag.toPath(), (sender.getName() + " " + Instant.now()).getBytes(StandardCharsets.UTF_8));
            } catch (Exception e) {
                sender.sendMessage(ChatColor.RED + "Couldn't write the confirm flag: " + e.getMessage());
                return true;
            }
        }

        lastRun = now;
        getLogger().info(sender.getName() + " ran /update" + (confirm ? " confirm" : ""));
        sender.sendMessage(ChatColor.GREEN + "Checking for a Spigot update"
                + (confirm ? " (Minecraft version jump confirmed)" : "") + ". Progress shows in chat.");

        getServer().getScheduler().runTaskAsynchronously(this, () -> {
            String error = null;
            try {
                Process p = new ProcessBuilder("schtasks", "/run", "/tn", task).redirectErrorStream(true).start();
                String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
                if (!p.waitFor(30, TimeUnit.SECONDS) || p.exitValue() != 0) error = "schtasks failed: " + out;
            } catch (Exception e) {
                error = "Couldn't start the update task: " + e.getMessage();
            }
            if (error != null) {
                final String msg = error;
                getServer().getScheduler().runTask(this, () -> {
                    sender.sendMessage(ChatColor.RED + msg);
                    getLogger().warning(msg);
                    lastRun = 0;
                });
            }
        });
        return true;
    }
}
