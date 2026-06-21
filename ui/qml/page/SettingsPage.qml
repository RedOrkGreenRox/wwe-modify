pragma ComponentBehavior: Bound
import QtQuick
import QtQml as Qml
import QtQuick.Layouts
import Qcm.Material as MD
import waywallen.control as WC
import waywallen.ui as W

MD.Page {
    id: root
    padding: 0
    showHeader: true
    showBackground: false
    title: 'Settings'
    scrolling: !m_flick.atYBeginning

    component SectionTitle: MD.Text {
        typescale: MD.Token.typescale.title_medium
        color: MD.Token.color.on_surface
    }

    component SectionHint: MD.Text {
        Layout.fillWidth: true
        typescale: MD.Token.typescale.body_medium
        color: MD.Token.color.on_surface_variant
        wrapMode: Text.WordWrap
    }

    component FieldLabel: MD.Text {
        typescale: MD.Token.typescale.label_medium
        color: MD.Token.color.on_surface_variant
    }

    component SectionPane: MD.Pane {
        Layout.fillWidth: true
        radius: 16
        backgroundColor: MD.MProp.color.surface
    }

    W.SettingsGetQuery {
        id: getQ
    }

    W.SettingsSetQuery {
        id: setQ
    }

    Connections {
        target: W.Notify
        function onDaemonReady() {
            getQ.reload();
        }
        function onSettingsChanged() {
            getQ.reload();
        }
    }

    Component.onCompleted: {
        if (W.Notify.daemonPhase === W.Notify.DaemonPhase.Ready)
            getQ.reload();
    }

    Shortcut {
        sequences: [StandardKey.Refresh, "F5", "Ctrl+R"]
        context: Qt.WidgetWithChildrenShortcut
        enabled: root.visible
        onActivated: getQ.reload()
    }

    // Same pattern as WallpaperPage._persistGlobalChange but routed
    // through a 200ms debounce — slider drags would otherwise flood
    // the daemon with one RPC per pixel.
    QtObject {
        id: m_pending
        property var nextGlobal: null
    }

    Qml.Timer {
        id: m_flush
        interval: 200
        repeat: false
        onTriggered: {
            const g = m_pending.nextGlobal;
            if (!g) return;
            setQ.global = g;
            setQ.plugins = getQ.plugins;
            setQ.reload();
            m_pending.nextGlobal = null;
        }
    }

    function _mut(fn) {
        if (Object.keys(getQ.global).length === 0)
            return;
        const base = m_pending.nextGlobal
                   ? m_pending.nextGlobal
                   : Object.assign({}, getQ.global);
        fn(base);
        m_pending.nextGlobal = base;
        m_flush.restart();
    }

    readonly property var kAutopauseModes: [
        { value: WC.AutopauseMode.AUTOPAUSE_MODE_NEVER,         label: qsTr("Never") },
        { value: WC.AutopauseMode.AUTOPAUSE_MODE_ANY,           label: qsTr("Any window open") },
        { value: WC.AutopauseMode.AUTOPAUSE_MODE_MAX,           label: qsTr("Maximized or fullscreen") },
        { value: WC.AutopauseMode.AUTOPAUSE_MODE_FOCUS,         label: qsTr("Window focused") },
        { value: WC.AutopauseMode.AUTOPAUSE_MODE_FOCUS_OR_MAX,  label: qsTr("Focused or maximized") },
        { value: WC.AutopauseMode.AUTOPAUSE_MODE_FULL_SCREEN,   label: qsTr("Fullscreen only") }
    ]

    function _autopauseIndex(mode) {
        for (let i = 0; i < kAutopauseModes.length; ++i)
            if (kAutopauseModes[i].value === mode) return i;
        return 0;
    }

    readonly property var kQueueModes: [
        { value: "sequential", label: qsTr("Sequential") },
        { value: "shuffle",    label: qsTr("Shuffle") },
        { value: "random",     label: qsTr("Random") }
    ]

    function _queueIndex(v) {
        for (let i = 0; i < kQueueModes.length; ++i)
            if (kQueueModes[i].value === v) return i;
        return 0;
    }

    contentItem: MD.VerticalFlickable {
        id: m_flick
        leftMargin: 16
        rightMargin: 16
        bottomMargin: 12

        ColumnLayout {
            width: m_flick.contentWidth
            spacing: 12

            // ---- General (UI-local, persisted via QSettings) ----------------
            SectionPane {
                contentItem: ColumnLayout {
                    spacing: 12

                    SectionTitle { text: qsTr("General") }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            MD.Text {
                                text: qsTr("Auto-expand sidebar")
                                typescale: MD.Token.typescale.body_medium
                                color: MD.Token.color.on_surface
                            }
                            MD.Text {
                                text: qsTr("Expand or collapse the sidebar with the window size.")
                                typescale: MD.Token.typescale.body_small
                                color: MD.Token.color.on_surface_variant
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }
                        }

                        MD.Switch {
                            id: m_sidebar_auto_expand
                            checked: W.Global.sidebarAutoExpand
                            onToggled: W.Global.sidebarAutoExpand = checked
                        }
                    }
                }
            }

            // ---- Auto-pause -------------------------------------------------
            SectionPane {
                contentItem: ColumnLayout {
                    spacing: 12

                    SectionTitle { text: qsTr("Auto-pause") }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        FieldLabel { text: qsTr("Trigger") }

                        MD.ComboBox {
                            id: m_mode_box
                            Layout.fillWidth: true
                            model: root.kAutopauseModes.map(o => o.label)
                            onActivated: idx => root._mut(g => {
                                const ap = Object.assign({},
                                    g.autopause || ({ mode: 0, resumeMs: 500 }));
                                ap.mode = root.kAutopauseModes[idx].value;
                                g.autopause = ap;
                            })
                        }
                        Binding {
                            target: m_mode_box
                            property: "currentIndex"
                            value: root._autopauseIndex(getQ.global?.autopause?.mode ?? 0)
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        FieldLabel { text: qsTr("Resume delay (ms)") }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            MD.Slider {
                                id: m_resume_slider
                                Layout.fillWidth: true
                                from: 0
                                to: 5000
                                stepSize: 100
                                onMoved: root._mut(g => {
                                    const ap = Object.assign({},
                                        g.autopause || ({ mode: 0, resumeMs: 500 }));
                                    ap.resumeMs = Math.round(value);
                                    g.autopause = ap;
                                })
                            }
                            Binding {
                                target: m_resume_slider
                                property: "value"
                                value: getQ.global?.autopause?.resumeMs ?? 500
                            }

                            MD.Text {
                                text: Math.round(m_resume_slider.value) + " ms"
                                typescale: MD.Token.typescale.body_small
                                color: MD.Token.color.on_surface_variant
                                Layout.preferredWidth: 64
                                horizontalAlignment: Text.AlignRight
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            MD.Text {
                                text: qsTr("Pause on lock screen")
                                typescale: MD.Token.typescale.body_medium
                                color: MD.Token.color.on_surface
                            }
                            MD.Text {
                                text: qsTr("Pause while the screen is locked")
                                typescale: MD.Token.typescale.body_small
                                color: MD.Token.color.on_surface_variant
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }
                        }

                        MD.Switch {
                            id: m_pause_on_lock
                            onToggled: root._mut(g => {
                                const ap = Object.assign({},
                                    g.autopause || ({ mode: 0, resumeMs: 500,
                                                      pauseOnLock: true,
                                                      pauseOnUserSwitch: true }));
                                ap.pauseOnLock = checked;
                                g.autopause = ap;
                            })
                        }
                        Binding {
                            target: m_pause_on_lock
                            property: "checked"
                            value: getQ.global?.autopause?.pauseOnLock ?? true
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            MD.Text {
                                text: qsTr("Pause on user switch")
                                typescale: MD.Token.typescale.body_medium
                                color: MD.Token.color.on_surface
                            }
                            MD.Text {
                                text: qsTr("Pause when switching to another user session")
                                typescale: MD.Token.typescale.body_small
                                color: MD.Token.color.on_surface_variant
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }
                        }

                        MD.Switch {
                            id: m_pause_on_user_switch
                            onToggled: root._mut(g => {
                                const ap = Object.assign({},
                                    g.autopause || ({ mode: 0, resumeMs: 500,
                                                      pauseOnLock: true,
                                                      pauseOnUserSwitch: true }));
                                ap.pauseOnUserSwitch = checked;
                                g.autopause = ap;
                            })
                        }
                        Binding {
                            target: m_pause_on_user_switch
                            property: "checked"
                            value: getQ.global?.autopause?.pauseOnUserSwitch ?? true
                        }
                    }
                }
            }

            // ---- Rotation ---------------------------------------------------
            SectionPane {
                contentItem: ColumnLayout {
                    spacing: 12

                    SectionTitle { text: qsTr("Rotation") }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        FieldLabel { text: qsTr("Queue mode") }

                        MD.ComboBox {
                            id: m_queue_box
                            Layout.fillWidth: true
                            model: root.kQueueModes.map(o => o.label)
                            onActivated: idx => root._mut(g => {
                                g.queueMode = root.kQueueModes[idx].value;
                            })
                        }
                        Binding {
                            target: m_queue_box
                            property: "currentIndex"
                            value: root._queueIndex(getQ.global?.queueMode ?? "sequential")
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            MD.TextField {
                                id: m_rot_field
                                Layout.preferredWidth: 120
                                mdState.dense: true
                                placeholderText: qsTr("Interval")
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator { bottom: 0 }
                                onEditingFinished: root._mut(g => {
                                    g.rotationSecs = Number(text) || 0;
                                })
                            }
                            // `when` gate keeps the Binding from clobbering
                            // mid-typed text when an unrelated settings
                            // round-trip refreshes `getQ.global`.
                            Binding {
                                target: m_rot_field
                                property: "text"
                                value: String(getQ.global?.rotationSecs ?? 0)
                                when: ! m_rot_field.activeFocus
                            }

                            MD.Text {
                                text: qsTr("s")
                                typescale: MD.Token.typescale.body_medium
                                color: MD.Token.color.on_surface_variant
                            }
                        }
                    }
                }
            }

            // ---- Keyboard shortcuts (nested under Settings) ----------
            //
            // We expose the hotkey editor as a `PagePopup` rather than
            // another sidebar entry. Settings is the natural home for
            // "things the user configures once and forgets about".
            SectionPane {
                contentItem: ColumnLayout {
                    spacing: 12

                    SectionTitle { text: qsTr("Keyboard") }

                    MD.Text {
                        Layout.fillWidth: true
                        text: qsTr("Rebind any action to any key combination. "
                                 + "A binding is one specific key press — like \"Ctrl+R\" or \"F5\". "
                                 + "An action can have any number of bindings.")
                        typescale: MD.Token.typescale.body_medium
                        color: MD.Token.color.on_surface_variant
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        MD.Button {
                            text: qsTr("Open keyboard settings")
                            icon.name: MD.Token.icon.keyboard
                            mdState.type: MD.Enum.BtFilledTonal
                            onClicked: MD.Util.showPopup(
                                'waywallen.ui/PagePopup',
                                { source: 'waywallen.ui/HotkeysSettingsPage' },
                                root)
                        }
                    }
                }
            }
        }
    }
}
