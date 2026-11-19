using System.Windows.Controls;
using BenchBar.Tray.Core;
using BenchBar.Tray.TestSupport;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The profile picker on the New Bench page (issue 175, PAR-5): the lines, a refused one off with the CLI's reason, a click that sets the install's profile.</summary>
public class WizardProfileViewTests
{
    private sealed class Host : IWizardHost
    {
        public void SetResumeAfterLogon(bool on) { }
        public bool RestartWindows() => true;
        public void AllowForeground() { }
        public string WindowsUserName => "Akash";
        public string? ConfiguredDistro => "Ubuntu-24.04";
        public bool Notifications { get; set; } = true;
        public bool OpenAtLogon { get; set; }
        public void OpenUrl(string url) { }
        public void CopyText(string text) { }
    }

    /// <summary>The list of today's CLI (<paramref name="list"/>, every profile answered), or one of an older CLI whose gate is asked per profile (<paramref name="olderCli"/>).</summary>
    private static async Task<WizardModel> NewBenchPage(bool refuseV16, string list = "profile-list-linux.json", bool olderCli = false)
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var service = WindowViewTests.Fixture(ready: true);
        Directory.CreateDirectory(Path.Combine(service.Root, "cli"));
        var text = File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), list));
        if (olderCli) text = System.Text.RegularExpressions.Regex.Replace(text, ",\"linux_supported\":[a-z]+,\"unsupported_reason\":(\"[^\"]*\"|null)", "");
        File.WriteAllText(Path.Combine(service.Root, "cli", "profile-list.json"), text);
        if (refuseV16)
            File.Copy(Path.Combine(FixtureFiles.Dir("setup"), "profile-gate-refused.jsonl"), Path.Combine(service.Root, "setup", "profile-gate-v16-lts.jsonl"));
        var model = new WizardModel(service, new Host());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        await model.ProfilesTask;
        return model;
    }

    private static ComboBox ProfileBox(WizardView view) =>
        Walk(view).OfType<ComboBox>().Single(b => System.Windows.Automation.AutomationProperties.GetName(b) == "Profile");

    [Fact]
    public async Task ThePickerListsEveryProfileAndSelectsV15Lts()
    {
        var model = await NewBenchPage(refuseV16: false);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            var box = ProfileBox(view);
            Assert.Equal(["v15-lts  Frappe/ERPNext v15 LTS", "v16-lts  Frappe/ERPNext v16 LTS", "acme  Acme ERP (team)", "acme-next  Acme on v16 (team)"],
                box.Items.OfType<ComboBoxItem>().Select(i => (string)i.Content));
            Assert.All(box.Items.OfType<ComboBoxItem>(), i => Assert.True(i.IsEnabled));
            Assert.Equal("v15-lts", (string)((ComboBoxItem)box.SelectedItem).Tag);
            Assert.Contains("Python 3.11, Node 22, MariaDB 10.11", Texts(view));
        });
    }

    [Fact]
    public async Task AProfileTheListSaysLinuxCannotInstallIsDisabledAndTheNoteSaysWhy()
    {
        var model = await NewBenchPage(refuseV16: false, list: "profile-list-linux-gated.json");
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            var items = ProfileBox(view).Items.OfType<ComboBoxItem>().ToList();
            var v16 = items.Single(i => (string)i.Tag == "v16-lts");
            Assert.False(v16.IsEnabled);
            Assert.EndsWith("(not available here)", (string)v16.Content);
            Assert.Contains(Texts(view), t => t.Contains("v16-lts: Not supported on Linux yet: it needs MariaDB 12.0, apt on this release gives 10.11", StringComparison.Ordinal));
        });
    }

    [Fact]
    public async Task ARefusedProfileOfAnOlderCliIsDisabledAndTheNoteSaysWhy()
    {
        var model = await NewBenchPage(refuseV16: true, olderCli: true);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            var items = ProfileBox(view).Items.OfType<ComboBoxItem>().ToList();
            var v16 = items.Single(i => (string)i.Tag == "v16-lts");
            Assert.False(v16.IsEnabled);
            Assert.EndsWith("(not available here)", (string)v16.Content);
            Assert.Contains(Texts(view), t => t.Contains("v16-lts: Profile v17-future is not supported on Linux yet: it needs MariaDB 12.0", StringComparison.Ordinal));
        });
    }

    [Fact]
    public async Task ChoosingATeamProfileInTheListSetsTheInstallsProfile()
    {
        var model = await NewBenchPage(refuseV16: false);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            var box = ProfileBox(view);
            box.SelectedItem = box.Items.OfType<ComboBoxItem>().Single(i => (string)i.Tag == "acme");
            Assert.Equal("acme", model.Profile);
            Assert.Equal("acme", model.Request.Profile);
        });
    }
}
