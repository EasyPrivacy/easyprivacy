import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/agent_status.dart';
import '../theme.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  static const _destinations = [
    _Destination('Overview', Icons.home_outlined, Icons.home_rounded),
    _Destination('Services', Icons.grid_view_outlined, Icons.grid_view_rounded),
    _Destination('Network', Icons.language_outlined, Icons.language_rounded),
    _Destination('Storage', Icons.storage_outlined, Icons.storage_rounded),
    _Destination('Backups', Icons.history_outlined, Icons.history_rounded),
    _Destination('Security', Icons.shield_outlined, Icons.shield_rounded),
    _Destination('Settings', Icons.settings_outlined, Icons.settings_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final status = widget.controller.status!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= 840;
        if (useRail) {
          return Scaffold(
            body: Row(
              children: [
                _DesktopNavigation(
                  selectedIndex: _selectedIndex,
                  destinations: _destinations,
                  onSelected: (index) => setState(() => _selectedIndex = index),
                  onDisconnect: widget.controller.disconnect,
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _SelectedPage(
                    selectedIndex: _selectedIndex,
                    status: status,
                    serverName: widget.controller.connection!.name,
                    isDemo: widget.controller.isDemo,
                    errorMessage: widget.controller.errorMessage,
                    onRefresh: widget.controller.refresh,
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: const _Brand(compact: true),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: widget.controller.refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          drawer: NavigationDrawer(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              setState(() => _selectedIndex = index);
              Navigator.pop(context);
            },
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(28, 24, 28, 16),
                child: _Brand(),
              ),
              for (final destination in _destinations)
                NavigationDrawerDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: Text(destination.label),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Divider(),
              ),
              ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: const Text('Disconnect'),
                onTap: widget.controller.disconnect,
              ),
            ],
          ),
          body: _SelectedPage(
            selectedIndex: _selectedIndex,
            status: status,
            serverName: widget.controller.connection!.name,
            isDemo: widget.controller.isDemo,
            errorMessage: widget.controller.errorMessage,
            onRefresh: widget.controller.refresh,
          ),
        );
      },
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({
    required this.selectedIndex,
    required this.destinations,
    required this.onSelected,
    required this.onDisconnect,
  });

  final int selectedIndex;
  final List<_Destination> destinations;
  final ValueChanged<int> onSelected;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 28, 14, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _Brand(),
          ),
          const SizedBox(height: 38),
          for (var index = 0; index < destinations.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _NavigationItem(
                destination: destinations[index],
                selected: selectedIndex == index,
                onTap: () => onSelected(index),
              ),
            ),
          const Spacer(),
          TextButton.icon(
            onPressed: onDisconnect,
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Disconnect server'),
          ),
        ],
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFF0F2F0) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                color: selected ? easyPrivacyInk : easyPrivacyMuted,
              ),
              const SizedBox(width: 16),
              Text(
                destination.label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: easyPrivacyInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectedPage extends StatelessWidget {
  const _SelectedPage({
    required this.selectedIndex,
    required this.status,
    required this.serverName,
    required this.isDemo,
    required this.errorMessage,
    required this.onRefresh,
  });

  final int selectedIndex;
  final AgentStatus status;
  final String serverName;
  final bool isDemo;
  final String? errorMessage;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (selectedIndex == 0) {
      return _OverviewPage(
        status: status,
        serverName: serverName,
        isDemo: isDemo,
        errorMessage: errorMessage,
        onRefresh: onRefresh,
      );
    }
    final destination = _DashboardScreenState._destinations[selectedIndex];
    return _ComingNextPage(destination: destination, status: status);
  }
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({
    required this.status,
    required this.serverName,
    required this.isDemo,
    required this.errorMessage,
    required this.onRefresh,
  });

  final AgentStatus status;
  final String serverName;
  final bool isDemo;
  final String? errorMessage;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        key: const Key('overview-scroll-view'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 30, 28, 44),
            sliver: SliverToBoxAdapter(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1360),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Your private cloud',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineLarge,
                              ),
                              const SizedBox(height: 12),
                              _ProtectionPill(isDemo: isDemo),
                            ],
                          ),
                        ),
                        if (MediaQuery.sizeOf(context).width >= 700)
                          IconButton.filledTonal(
                            tooltip: 'Refresh server',
                            onPressed: onRefresh,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                      ],
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 18),
                      _RefreshWarning(message: errorMessage!),
                    ],
                    const SizedBox(height: 24),
                    _SummaryGrid(status: status),
                    const SizedBox(height: 24),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        if (constraints.maxWidth >= 980) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 5,
                                child: _ServicesPanel(status: status),
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                flex: 5,
                                child: Column(
                                  children: [
                                    _InfrastructurePanel(
                                      status: status,
                                      serverName: serverName,
                                    ),
                                    const SizedBox(height: 24),
                                    _BackupPanel(status: status),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            _ServicesPanel(status: status),
                            const SizedBox(height: 24),
                            _InfrastructurePanel(
                              status: status,
                              serverName: serverName,
                            ),
                            const SizedBox(height: 24),
                            _BackupPanel(status: status),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProtectionPill extends StatelessWidget {
  const _ProtectionPill({required this.isDemo});

  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: easyPrivacySoftGreen,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, size: 10, color: easyPrivacyGreen),
          const SizedBox(width: 9),
          Text(isDemo ? 'Demo system is protected' : 'Server is connected'),
        ],
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.status});

  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1080
            ? 4
            : constraints.maxWidth >= 560
            ? 2
            : 1;
        const gap = 16.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            _SummaryCard(
              width: width,
              icon: Icons.grid_view_rounded,
              label: 'Services',
              value: status.services.isEmpty
                  ? 'None installed'
                  : '${status.healthyServiceCount} healthy',
            ),
            _SummaryCard(
              width: width,
              icon: Icons.history_rounded,
              label: 'Backups',
              value: status.backups.isEmpty ? 'Not configured' : 'Protected',
            ),
            _SummaryCard(
              width: width,
              icon: Icons.storage_rounded,
              label: 'Storage',
              value: '${status.storage.availableLabel} free',
            ),
            _SummaryCard(
              width: width,
              icon: Icons.shield_outlined,
              label: 'Agent',
              value: 'v${status.agentVersion}',
            ),
          ],
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 126,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Row(
            children: [
              _GreenIcon(icon: icon),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(color: easyPrivacyGreen),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServicesPanel extends StatelessWidget {
  const _ServicesPanel({required this.status});

  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Services', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            if (status.services.isEmpty)
              const _EmptyState(
                icon: Icons.widgets_outlined,
                title: 'No services installed yet',
                message: 'Private DNS will be the first managed service added.',
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 560 ? 3 : 2;
                  const gap = 14.0;
                  final width =
                      (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: status.services
                        .map(
                          (service) =>
                              _ServiceCard(width: width, service: service),
                        )
                        .toList(growable: false),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.width, required this.service});

  final double width;
  final ManagedService service;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      constraints: const BoxConstraints(minHeight: 170),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: easyPrivacyBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_serviceIcon(service.id), size: 42, color: easyPrivacyGreen),
          const SizedBox(height: 18),
          Text(
            service.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          _HealthLabel(health: service.health),
        ],
      ),
    );
  }
}

class _InfrastructurePanel extends StatelessWidget {
  const _InfrastructurePanel({required this.status, required this.serverName});

  final AgentStatus status;
  final String serverName;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Infrastructure',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const _GreenIcon(icon: Icons.dns_outlined, size: 60),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        serverName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${status.hostname} · ${status.operatingSystem}/${status.architecture}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const _HealthLabel(health: HealthState.healthy),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 18),
            Wrap(
              spacing: 26,
              runSpacing: 12,
              children: [
                _InlineMetric(label: 'Uptime', value: status.uptimeLabel),
                _InlineMetric(
                  label: 'Memory free',
                  value: status.memory.availableLabel,
                ),
                _InlineMetric(
                  label: 'Disk total',
                  value: status.storage.totalLabel,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BackupPanel extends StatelessWidget {
  const _BackupPanel({required this.status});

  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Backup locations',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            if (status.backups.isEmpty)
              const _EmptyState(
                icon: Icons.history_outlined,
                title: 'Backups are not configured',
                message: 'Backup setup is planned after server pairing and monitoring.',
              )
            else
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: easyPrivacyBorder),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    for (
                      var index = 0;
                      index < status.backups.length;
                      index++
                    ) ...[
                      _BackupRow(location: status.backups[index]),
                      if (index != status.backups.length - 1)
                        const Divider(height: 1, indent: 58),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BackupRow extends StatelessWidget {
  const _BackupRow({required this.location});

  final BackupLocation location;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const _GreenIcon(icon: Icons.home_outlined, size: 34),
          const SizedBox(width: 12),
          Expanded(child: Text(location.name)),
          _HealthLabel(health: location.health),
        ],
      ),
    );
  }
}

class _ComingNextPage extends StatelessWidget {
  const _ComingNextPage({required this.destination, required this.status});

  final _Destination destination;
  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: Column(
                children: [
                  _GreenIcon(icon: destination.selectedIcon, size: 70),
                  const SizedBox(height: 24),
                  Text(
                    destination.label,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${destination.label} management is part of the next vertical slice. '
                    'The current agent is connected to ${status.hostname} and reports real system status.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(color: easyPrivacyMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GreenIcon extends StatelessWidget {
  const _GreenIcon({required this.icon, this.size = 54});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: easyPrivacySoftGreen,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: easyPrivacyDarkGreen, size: size * 0.5),
    );
  }
}

class _HealthLabel extends StatelessWidget {
  const _HealthLabel({required this.health});

  final HealthState health;

  @override
  Widget build(BuildContext context) {
    final color = switch (health) {
      HealthState.healthy => easyPrivacyGreen,
      HealthState.degraded => const Color(0xFF9B6510),
      HealthState.unavailable => Theme.of(context).colorScheme.error,
      HealthState.unknown => easyPrivacyMuted,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 9, color: color),
        const SizedBox(width: 7),
        Text(health.label, style: TextStyle(color: color)),
      ],
    );
  }
}

class _InlineMetric extends StatelessWidget {
  const _InlineMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      decoration: BoxDecoration(
        color: easyPrivacySurface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: easyPrivacyGreen, size: 38),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _RefreshWarning extends StatelessWidget {
  const _RefreshWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5E2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFF9B6510)),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: compact ? 34 : 42,
          child: Image.asset('assets/easyprivacy-mark.png'),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'EasyPrivacy',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ),
      ],
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

IconData _serviceIcon(String id) {
  return switch (id) {
    'private-network' => Icons.hub_outlined,
    'private-dns' => Icons.language_rounded,
    'private-drive' => Icons.folder_outlined,
    'passwords' => Icons.key_rounded,
    'photos' => Icons.image_outlined,
    'media' => Icons.play_circle_outline_rounded,
    _ => Icons.widgets_outlined,
  };
}
