module;
#include "QExtra/macro_qt.hpp"

#ifdef Q_MOC_RUN
#    include "waywallen/query/playlist_query.moc"
#endif

export module waywallen:query.playlist;
export import :query.query;

namespace waywallen
{

export class PlaylistListQuery : public Query, public QueryExtra<control::v1::Response, PlaylistListQuery> {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantList playlists READ playlists NOTIFY playlistsChanged FINAL)
public:
    PlaylistListQuery(QObject* parent = nullptr);
    auto playlists() const -> const QVariantList&;
    void reload() override;
    Q_SIGNAL void playlistsChanged();
private:
    QVariantList m_playlists;
};

export class PlaylistStatusQuery : public Query, public QueryExtra<control::v1::Response, PlaylistStatusQuery> {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantList displays READ displays NOTIFY displaysChanged FINAL)
    Q_PROPERTY(qint64 autoAttachId READ autoAttachId NOTIFY displaysChanged FINAL)
public:
    PlaylistStatusQuery(QObject* parent = nullptr);
    auto displays() const -> const QVariantList&;
    qint64 autoAttachId() const { return m_autoAttachId; }
    void reload() override;
    Q_SIGNAL void displaysChanged();
private:
    QVariantList m_displays;
    qint64 m_autoAttachId = 0;
};

export class PlaylistMutationQuery : public Query, public QueryExtra<control::v1::Response, PlaylistMutationQuery> {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(qint64 createdId READ createdId NOTIFY createdIdChanged FINAL)
public:
    PlaylistMutationQuery(QObject* parent = nullptr);
    qint64 createdId() const { return m_createdId; }

    Q_INVOKABLE void create(const QString& name, int mode, int intervalSecs, const QVariantList& itemIds);
    Q_INVOKABLE void remove(qint64 id);
    Q_INVOKABLE void rename(qint64 id, const QString& name);
    Q_INVOKABLE void setItems(qint64 id, const QVariantList& itemIds);
    Q_INVOKABLE void setMode(qint64 id, int mode);
    Q_INVOKABLE void setInterval(qint64 id, int intervalSecs);
    Q_INVOKABLE void activate(qint64 id, const QVariantList& displayIds, bool autoAttach);
    Q_INVOKABLE void deactivate(const QVariantList& displayIds, qint64 clearAutoAttach);
    Q_INVOKABLE void exportPlaylist(qint64 id, const QString& path);
    Q_INVOKABLE void importPlaylist(const QString& path, qint64 intoId);
    Q_INVOKABLE void jumpTo(qint64 id, const QString& entryId);

    void reload() override {}

    Q_SIGNAL void createdIdChanged();
    Q_SIGNAL void done();
    Q_SIGNAL void exported();
    Q_SIGNAL void imported(qint64 id, int missingCount);
private:
    void send(proto::Request req, bool captureCreate);
    qint64 m_createdId = 0;
};

}
