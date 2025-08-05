# Import BurnToast
Import-Module -Name BurntToast

# Load assemblies for Windows Forms, drawing and theme
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type @"
using System;
using System.Runtime.InteropServices;

// Dark context menu
public class UxTheme
{
	[DllImport("UxTheme.dll", EntryPoint = "#135")]
	public static extern int SetPreferredAppMode([In] int preferredAppMode);

	[DllImport("UxTheme.dll", EntryPoint = "#136")]
	public static extern void FlushMenuThemes();
}

// Dark title bar and backdrop
public class DwmApi
{
	[StructLayout(LayoutKind.Sequential)]
	public struct MARGINS
	{
		public int cxLeftWidth;
		public int cxRightWidth;
		public int cyTopHeight;
		public int cyBottomHeight;
	};

	[DllImport("DwmApi.dll")]
	public static extern int DwmExtendFrameIntoClientArea(
		[In] IntPtr hwnd, [In] ref MARGINS marginsInset);

	public static int ExtendFrame(IntPtr hwnd)
	{
		MARGINS inset = new MARGINS()
		{
			cxLeftWidth = -1,
			cxRightWidth = -1,
			cyTopHeight = -1,
			cyBottomHeight = -1,
		};
		return DwmExtendFrameIntoClientArea(hwnd, ref inset);
	}

	[DllImport("DwmApi.dll")]
	public static extern int DwmSetWindowAttribute(
		[In] IntPtr hwnd, [In] int dwAttribute, [In] ref int pvAttribute, [In] int cbAttribute);

	public static int SetDwmAttrib(IntPtr hwnd, int attrib, int flag)
	{
		return DwmSetWindowAttribute(hwnd, attrib, ref flag, Marshal.SizeOf(flag));
	}
}
"@

# Set context menu mode
$PREFERRED_APPMODE_ALLOWDARK = 1;
[UxTheme]::SetPreferredAppMode($PREFERRED_APPMODE_ALLOWDARK) | Out-Null
[UxTheme]::FlushMenuThemes() | Out-Null

# Define icon paths
$defaultIconPath = "$PSScriptRoot\up-to-date.ico"
$updateIconPath = "$PSScriptRoot\updates-available.ico"
$json = "$PSScriptRoot\settings.json"

# Define settings
if (-not (Test-Path $json)) {

	# Define default settings as a hashtable
	$defaultSettings = @{
		interval = 2
		backdrop = 2
	}

	$jsonContent = $defaultSettings | ConvertTo-Json
	$jsonContent | Out-File -FilePath $json -Encoding UTF8
}
$settingsJson = Get-Content -Path $json | ConvertFrom-Json

# Timer interval between checks (hours to milliseconds)
$timerInterval = $settingsJson.interval*60*60*1000

# Create and configure the NotifyIcon object
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Visible = $true
$notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($defaultIconPath)

# Initialize Script variables
$Script:ChocoState = @{
	"UpdatesAvailable" = $false
	"AvailableUpdates" = @()
	"PinnedUpdates" = @()
}
$Script:updateList = ""

# Execute a PowerShell command and return the output
function Invoke-PowerShellCommand {
	param (
		[string]$command
	)
	# Redirect the output within the command string
	$output = Invoke-Expression "$command *>&1 | Out-String"
	return $output.Trim() # Remove the trailing newline character
}

# Show form
function Show-Form {
	param (
		[string]$title,
		[string]$text,
		[string[]]$packages
	)

	[xml]$xaml = @"
	<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
			xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
			Title="$title"
			SizeToContent="WidthAndHeight"
			ResizeMode="NoResize"
			WindowStartupLocation="CenterScreen"
			Icon="$updateIconPath"
			Background="Transparent">

		<Window.Resources>
			<Style TargetType="CheckBox">
				<Setter Property="Foreground" Value="{DynamicResource TextForegroundBrush}"/>
				<Setter Property="Template">
					<Setter.Value>
						<ControlTemplate TargetType="CheckBox">
							<StackPanel Orientation="Horizontal">
								<Border x:Name="CheckMarkBorder"
										BorderBrush="{DynamicResource TextForegroundBrush}"
										BorderThickness="1"
										Background="Transparent"
										CornerRadius="3">
									<Path x:Name="CheckMark"
										Stroke="{DynamicResource TextForegroundBrush}"
										StrokeThickness="1"
										Data="M1,8 L5,12 L13,2"
										Visibility="Hidden"/>
								</Border>
								<ContentPresenter Margin="5,0,0,0"/>
							</StackPanel>
							<ControlTemplate.Triggers>
								<Trigger Property="IsChecked" Value="True">
									<Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
								</Trigger>
								<Trigger Property="IsMouseOver" Value="True">
									<Setter TargetName="CheckMarkBorder" Property="BorderBrush" Value="Gray"/>
								</Trigger>
							</ControlTemplate.Triggers>
						</ControlTemplate>
					</Setter.Value>
				</Setter>
			</Style>

			<Style TargetType="Button">
				<Setter Property="Foreground" Value="{DynamicResource TextForegroundBrush}"/>
				<Setter Property="Template">
					<Setter.Value>
						<ControlTemplate TargetType="Button">
							<Border x:Name="ButtonBorder"
									Background="Transparent"
									BorderBrush="{DynamicResource TextForegroundBrush}"
									BorderThickness="1"
									CornerRadius="3">
								<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
							</Border>
							<ControlTemplate.Triggers>
								<Trigger Property="IsMouseOver" Value="True">
									<Setter TargetName="ButtonBorder" Property="BorderBrush" Value="Gray"/>
								</Trigger>
								<Trigger Property="IsFocused" Value="True">
									<Setter TargetName="ButtonBorder" Property="BorderBrush" Value="Gray"/>
								</Trigger>
							</ControlTemplate.Triggers>
						</ControlTemplate>
					</Setter.Value>
				</Setter>
			</Style>

			<Style TargetType="ListBoxItem">
				<Setter Property="IsTabStop" Value="False"/>
				<Setter Property="Template">
					<Setter.Value>
						<ControlTemplate TargetType="ListBoxItem">
							<Border Padding="2">
								<ContentPresenter/>
							</Border>
						</ControlTemplate>
					</Setter.Value>
				</Setter>
			</Style>
		</Window.Resources>

		<Grid Margin="10">
			<Grid.RowDefinitions>
				<RowDefinition Height="Auto"/>
				<RowDefinition Height="*"/>
				<RowDefinition Height="Auto"/>
			</Grid.RowDefinitions>

			<TextBlock x:Name="LabelText" TextWrapping="Wrap" Foreground="{DynamicResource TextForegroundBrush}" Margin="5">$text</TextBlock>

			<ListBox x:Name="ListBoxItems" Grid.Row="1" SelectionMode="Multiple" BorderThickness="0" Padding="5" Background="Transparent">
				<ListBox.ItemTemplate>
					<DataTemplate>
						<CheckBox Content="{Binding Name}"
								IsChecked="{Binding IsChecked, Mode=TwoWay}"/>
					</DataTemplate>
				</ListBox.ItemTemplate>
			</ListBox>

			<StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="5">
				<Button x:Name="YesButton" Content="Yes" MinWidth="75" Margin="5"/>
				<Button x:Name="NoButton" Content="No" MinWidth="75" Margin="5"/>
			</StackPanel>
		</Grid>
	</Window>
"@

	$reader = New-Object System.Xml.XmlNodeReader $xaml
	$window = [Windows.Markup.XamlReader]::Load($reader)

	$window.Add_Loaded({
		# Constants
		$DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
		$DWMWA_SYSTEMBACKDROP_TYPE = 38;

		$windowsBuild = [System.Environment]::OSVersion.Version

		$theme = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme"

		# Handle newlines in text
		$textBlock = $window.FindName("LabelText")
		$textBlock.Inlines.Clear()
		$lines = $text -split "`n"

		for ($i = 0; $i -lt $lines.Count; $i++) {
			$textBlock.Inlines.Add($lines[$i])
			if ($i -lt $lines.Count - 1) {
				$textBlock.Inlines.Add([System.Windows.Documents.LineBreak]::new())
			}
		}

		# Check compatibility
		if ($windowsBuild.Build -ge 22000) {
			# Get handles
			$helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
			$hwnd = $helper.Handle
			$src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)

			# Set transparent backgrond color
			# and extend frame across entire window
			$src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
			[DwmApi]::ExtendFrame($hwnd)

			# Set title bar and text color
			If ($theme.AppsUseLightTheme -eq 0) {
				$window.Resources["TextForegroundBrush"] = [System.Windows.Media.Brushes]::White
				[DwmApi]::SetDwmAttrib($hwnd, $DWMWA_USE_IMMERSIVE_DARK_MODE, $true)
			} else {
				$window.Resources["TextForegroundBrush"] = [System.Windows.Media.Brushes]::Black
			}

			# Set backdrop
			# Check compatibility
			if ($windowsBuild.Build -ge 22621) {
				[DwmApi]::SetDwmAttrib($hwnd, $DWMWA_SYSTEMBACKDROP_TYPE, $settingsJson.backdrop)
			}
		} else {
			$window.Background = [System.Windows.Media.Brushes]::White
			$window.Resources["TextForegroundBrush"] = [System.Windows.Media.Brushes]::Black
		}
	})

	$listBox = $window.FindName("ListBoxItems")
	$yesButton = $window.FindName("YesButton")
	$noButton = $window.FindName("NoButton")

	# Populate data (with data binding)
	$items = New-Object System.Collections.ObjectModel.ObservableCollection[PSCustomObject]
	foreach ($package in $packages) {
		$items.Add([PSCustomObject]@{ Name = $package; IsChecked = $true })
	}
	$listBox.ItemsSource = $items

	$yesButton.Add_Click({
		$window.DialogResult = $true
		$window.Close()
	})

	$noButton.Add_Click({
		$window.DialogResult = $false
		$window.Close()
	})

	if ($window.ShowDialog() -eq $true) {
		return $items | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { $_.Name }
	}
}

# Update the Chocolatey state
function Update-ChocoState {
	param (
		[string]$output
	)

	# Reset the state
	$Script:ChocoState["UpdatesAvailable"] = $false
	$Script:ChocoState["AvailableUpdates"] = @()
	$Script:ChocoState["PinnedUpdates"] = @()

	# Process the output for updates and failed installs
	$text = $output -split "`n"
	$updateLines = $text | Where-Object { $_.Trim() -ne "" }
	$availableUpdates = $updateLines | Where-Object {
		$_ -match '^\s*[^|]+\|[^|]+\|[^|]+\|(?:true|false)\s*$'
	}
	$structuredUpdates = $availableUpdates | ForEach-Object {
		$parts = $_ -split '\|'
		[PSCustomObject]@{
			Id = $parts[0].Trim()
			Pinned = $parts[3].Trim()
		}
	}
	$filteredUpdates = $structuredUpdates | Where-Object {
		-not ($_.Id -like '*.install') -and $_.Pinned -ne 'true'
	}
	$pinnedUpdates = $structuredUpdates | Where-Object {
		$_.Pinned -eq 'true'
	}
	$Script:ChocoState["PinnedUpdates"] = $pinnedUpdates.Id

	# Update state if updates are available
	if ($availableUpdates.Count -gt 0) {
		$Script:ChocoState["UpdatesAvailable"] = $true
		$Script:ChocoState["AvailableUpdates"] = $filteredUpdates.Id
	}
}

# Update Chocolatey packages
function Update-ChocoPackage {
	param (
		[string[]]$package
	)
	$package | ForEach-Object {
		Start-Process "cmd.exe" -ArgumentList "/c choco upgrade $_" -WindowStyle Minimized -Wait
	}
}

# Set the NotifyIcon tooltip text with a character limit
function Set-NotifyIconTooltip {
	param (
		[string]$fullText
	)
	$characterLimit = 59

	if ($fullText.Length -gt $characterLimit) {
		$lastSpaceIndex = $fullText.LastIndexOf(' ', $characterLimit)
		$tooltipText = $fullText.Substring(0, $lastSpaceIndex) + " ..."
	} else {
		$tooltipText = $fullText
	}
	$notifyIcon.Text = $tooltipText
}

# Check for updates, update the icon and tooltip
function Update-NotifyIcon {
	$notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($defaultIconPath)
	Set-NotifyIconTooltip -fullText 'Checking for updates...'

	if (-not (Test-Connection github.com -Count 1 -Quiet)) {
		Set-NotifyIconTooltip -fullText "Error: Check internet connection"
		New-BurntToastNotification -Text Error, "Check internet connection" -AppLogo $defaultIconPath
	} else {
		$outputFromOutdated = Invoke-PowerShellCommand -command "choco outdated"

		if ($outputFromOutdated) {
			Update-ChocoState -output $outputFromOutdated

			if ($Script:ChocoState["AvailableUpdates"].Count -gt 0) {
				$notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($updateIconPath)
				$count = $Script:ChocoState["AvailableUpdates"].Count
				$Script:updateList = $Script:ChocoState["AvailableUpdates"] -join ', '
				Set-NotifyIconTooltip -fullText "$count update(s) available:`n$Script:updateList"
				New-BurntToastNotification -Text "Updates Available", "$count update(s) available:`n$Script:updateList" -AppLogo $updateIconPath
			} else {
				$notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($defaultIconPath)
				Set-NotifyIconTooltip -fullText 'All applications are up to date'
				$Script:updateList = ""
			}
		}
	}
}

# Helper function to create a menu item
function New-MenuItem {
	param (
		[string]$text,
		$action,
		[bool]$isEnabled = $true
	)
	$menuItem = New-Object System.Windows.Forms.MenuItem
	$menuItem.Text = $text
	$menuItem.Enabled = $isEnabled
	if ($action) {
		$menuItem.Add_Click($action)
	}
	return $menuItem
}

# Create context menu
$contextMenu = New-Object System.Windows.Forms.ContextMenu
$contextMenu.MenuItems.Add((New-MenuItem -text 'ChocoTray' -action $null -isEnabled $false)) | Out-Null # Header
$contextMenu.MenuItems.Add((New-MenuItem -text '-')) | Out-Null # Separator
$contextMenu.MenuItems.Add((New-MenuItem -text 'Check for updates' -action { Update-NotifyIcon })) | Out-Null
$contextMenu.MenuItems.Add((New-MenuItem -text 'Update all' -action {
	if ($Script:ChocoState["AvailableUpdates"]) {
		$message = "Are you sure you want to update all?`nThe following updates are available:"
		$title = "Updates"

		$result = Show-Form -title $title -text $message -packages $Script:ChocoState["AvailableUpdates"]

		if ($result) {
			Update-ChocoPackage -package $result
			}
		} else {
			return
		}
		Update-NotifyIcon
	}
})) | Out-Null
$contextMenu.add_Popup({
	$menuItem = $contextMenu.MenuItems | Where-Object { $_.Text -eq 'Update all' }
	if ($menuItem) {
		$menuItem.Enabled = $Script:ChocoState["AvailableUpdates"].Count -gt 0
	}
})
$contextMenu.MenuItems.Add((New-MenuItem -text 'Exit' -action { $notifyIcon.Visible = $false; [System.Windows.Forms.Application]::Exit() })) | Out-Null

# Assign the context menu to the NotifyIcon
$notifyIcon.ContextMenu = $contextMenu

# Timer setup to check for updates periodically
$timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = $timerInterval; Enabled = $true }
$timer.Add_Tick({ Update-NotifyIcon })
$timer.Start()

# Initial check for updates and keep the script running
Update-NotifyIcon
[System.GC]::Collect()
[void] [System.Windows.Forms.Application]::Run()
