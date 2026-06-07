module;
#include "control.qpb.h"

export module waywallen:proto;

namespace proto = waywallen::control::v1;

export namespace waywallen::control::v1
{
using proto::StatusGadget::Status;

using proto::Request;
using proto::Response;
using proto::ServerFrame;
using proto::Event;
using proto::DisplaySnapshot;
using proto::DisplayChanged;
using proto::DisplayRemoved;
using proto::Empty;

using proto::HealthRequest;
using proto::HealthResponse;

using proto::RendererSpawnRequest;
using proto::RendererSpawnResponse;
using proto::RendererListRequest;
using proto::RendererListResponse;
using proto::RendererInstance;
using proto::RendererPlayRequest;
using proto::RendererPauseRequest;
using proto::RendererMouseRequest;
using proto::RendererFpsRequest;
using proto::RendererKillRequest;

using proto::RendererPluginListRequest;
using proto::RendererPluginListResponse;
using proto::RendererPluginInfo;
using proto::SettingSchema;

using proto::WallpaperEntry;
using proto::WallpaperListRequest;
using proto::WallpaperListResponse;
using proto::WallpaperScanRequest;
using proto::WallpaperScanResponse;
using proto::WallpaperSyncFinished;
using proto::WallpaperApplyRequest;
using proto::WallpaperApplyResponse;
using proto::WallpaperGetRequest;
using proto::WallpaperGetResponse;
using proto::WallpaperPropertySetRequest;
using proto::WallpaperPropertySetResponse;
using proto::WallpaperApplyViaPortalRequest;
using proto::WallpaperApplyViaPortalResponse;

using proto::StatusSync;
using proto::DaemonPhaseGadget::DaemonPhase;

using proto::SourceListRequest;
using proto::SourceListResponse;
using proto::SourcePluginInfo;

using proto::DisplayInfo;
using proto::DisplayLinkInfo;
using proto::DisplayListRequest;
using proto::DisplayListResponse;
using proto::LayoutOverride;
using proto::DisplayLayoutSetRequest;
using proto::DisplayLayoutSetResponse;
using proto::DisplayRenameRequest;
using proto::DisplayRenameResponse;

using proto::RemoteAvailabilityRequest;
using proto::RemoteAvailabilityResponse;
using proto::RemoteItem;
using proto::RemoteSearchRequest;
using proto::RemoteSearchResponse;
using proto::RemoteSortGadget::RemoteSort;
using proto::RemoteDownloadRequest;
using proto::RemoteDownloadResponse;
using proto::RemoteDownloadProgress;
using proto::RemoteDownloadStateGadget::RemoteDownloadState;
using proto::RemoteUninstallRequest;
using proto::RemoteUninstallResponse;
using proto::RemoteDetailsRequest;
using proto::RemoteDetailsResponse;

using proto::GpuInfo;
using proto::GpuListRequest;
using proto::GpuListResponse;

using proto::PluginInstallRequest;
using proto::PluginInstallResponse;
using proto::PluginInfo;
using proto::PluginListRequest;
using proto::PluginListResponse;

using proto::TagListRequest;
using proto::TagListResponse;
using proto::ContentRatingListRequest;
using proto::ContentRatingListResponse;

using proto::LibraryInstance;
using proto::LibraryListRequest;
using proto::LibraryListResponse;
using proto::LibraryAddRequest;
using proto::LibraryRemoveRequest;
using proto::LibraryAutoDetectRequest;
using proto::LibraryAutoDetectResponse;
using proto::LibrarySnapshot;
using proto::LibraryChanged;
using proto::LibraryRemoved;

using proto::GlobalSettings;
using proto::PluginSettings;
using proto::SettingsGetRequest;
using proto::SettingsGetResponse;
using proto::SettingsSetRequest;
using proto::SettingsChanged;
using proto::LayoutPrefs;
using proto::FillModeGadget::FillMode;
using proto::AlignGadget::Align;
using proto::RotationGadget::Rotation;
using proto::AutopauseSettings;
using proto::AutopauseModeGadget::AutopauseMode;

using proto::WallpaperFilterRule;
using proto::WallpaperFilterTypeGadget::WallpaperFilterType;
using proto::WallpaperStringFilter;
using proto::WallpaperIntFilter;
using proto::WallpaperTagFilter;
using proto::StringConditionGadget::StringCondition;
using proto::IntConditionGadget::IntCondition;
using proto::LogicOpGadget::LogicOp;
using proto::FilterLogic;
using proto::WallpaperSortRule;
using proto::WallpaperSortKeyGadget::WallpaperSortKey;
using proto::SortDirectionGadget::SortDirection;
using proto::PlaylistModeGadget::PlaylistMode;
using proto::PlaylistSummary;
using proto::PlaylistListRequest;
using proto::PlaylistListResponse;
using proto::PlaylistCreateRequest;
using proto::PlaylistCreateResponse;
using proto::PlaylistDeleteRequest;
using proto::PlaylistRenameRequest;
using proto::PlaylistSetItemsRequest;
using proto::PlaylistSetModeRequest;
using proto::PlaylistSetIntervalRequest;
using proto::PlaylistActivateRequest;
using proto::PlaylistDeactivateRequest;
using proto::PlaylistStatusRequest;
using proto::PlaylistStatusResponse;
using proto::PlaylistDisplayStatus;
using proto::PlaylistExportRequest;
using proto::PlaylistExportResponse;
using proto::PlaylistImportRequest;
using proto::PlaylistImportResponse;
using proto::PlaylistJumpToRequest;
using proto::PlaylistChanged;
} // namespace waywallen::control::v1
