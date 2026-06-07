module;
#include "waywallen/query/plugin_query.moc.h"
#undef assert
#include <rstd/macro.hpp>

module waywallen;
import :query.plugin;
import :app;

using namespace Qt::Literals::StringLiterals;
using namespace qextra::prelude;

namespace proto = waywallen::control::v1;

namespace waywallen
{

// Flatten one renderer component (+ its settings schema) into a QVariantMap,
// matching RendererPluginListQuery so PluginSettingsPopup can consume it.
static auto renderer_to_map(const proto::RendererPluginInfo& r) -> QVariantMap {
    QVariantMap m;
    m[u"name"_s]    = r.name();
    m[u"version"_s] = r.version();
    QStringList types;
    for (const auto& t : r.types()) {
        types.append(t);
    }
    m[u"types"_s] = types;

    QVariantList settings;
    for (const auto& s : r.settings()) {
        QVariantMap sm;
        sm[u"key"_s]             = s.key();
        sm[u"type"_s]            = static_cast<int>(s.type());
        sm[u"default_value"_s]   = s.defaultValue();
        sm[u"identity"_s]        = s.identity();
        sm[u"label_key"_s]       = s.labelKey();
        sm[u"description_key"_s] = s.descriptionKey();
        sm[u"min"_s]             = s.min();
        sm[u"max"_s]             = s.max();
        sm[u"step"_s]            = s.step();
        QStringList choices;
        for (const auto& c : s.choices()) {
            choices.append(c);
        }
        sm[u"choices"_s] = choices;
        sm[u"group"_s]   = s.group();
        sm[u"order"_s]   = static_cast<int>(s.order());
        settings.append(sm);
    }
    m[u"settings"_s] = settings;
    return m;
}

// --- PluginListQuery --------------------------------------------------------

PluginListQuery::PluginListQuery(QObject* parent): Query(parent) {}

auto PluginListQuery::plugins() const -> const QVariantList& { return m_plugins; }

void PluginListQuery::reload() {
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req = proto::Request {};
    req.setPluginList(proto::PluginListRequest {});

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req)]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(self->get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self](const proto::Response& rsp) {
            QVariantList items;
            for (const auto& p : rsp.pluginList().plugins()) {
                QVariantMap m;
                m[u"id"_s]        = p.id_proto();
                m[u"name"_s]      = p.name();
                m[u"version"_s]   = p.version();
                m[u"hasSource"_s] = p.hasSource();
                m[u"system"_s]    = p.system();
                QVariantList renderers;
                for (const auto& r : p.renderers()) {
                    renderers.append(renderer_to_map(r));
                }
                m[u"renderers"_s] = renderers;
                items.append(m);
            }
            self->m_plugins = std::move(items);
            Q_EMIT self->pluginsChanged();
        });
        co_return;
    });
}

PluginInstallQuery::PluginInstallQuery(QObject* parent): Query(parent) {}

auto PluginInstallQuery::zipPath() const -> const QString& { return m_zip_path; }
void PluginInstallQuery::setZipPath(const QString& v) {
    if (m_zip_path == v) return;
    m_zip_path = v;
    Q_EMIT zipPathChanged();
}
auto PluginInstallQuery::pluginId() const -> const QString& { return m_plugin_id; }
auto PluginInstallQuery::needsRestart() const -> bool { return m_needs_restart; }

void PluginInstallQuery::reload() {
    if (m_zip_path.isEmpty()) return;
    setStatus(Status::Querying);
    auto backend = App::instance()->backend();

    auto req   = proto::Request {};
    auto inner = proto::PluginInstallRequest {};
    inner.setZipPath(m_zip_path);
    req.setPluginInstall(std::move(inner));

    auto self = QWatcher { this };
    spawn([self, backend, req = std::move(req)]() mutable -> task<void> {
        auto result = co_await backend->send(std::move(req));
        co_await asio::post(asio::bind_executor(self->get_executor(), use_task));
        if (! self) co_return;

        self->inspect_set(result, [self](const proto::Response& rsp) {
            const auto& r         = rsp.pluginInstall();
            self->m_plugin_id     = r.pluginId();
            self->m_needs_restart = r.needsRestart();
            Q_EMIT self->resultChanged();
            Q_EMIT self->installed(self->m_plugin_id, self->m_needs_restart);
        });
        co_return;
    });
}

} // namespace waywallen

#include "waywallen/query/plugin_query.moc.cpp"
