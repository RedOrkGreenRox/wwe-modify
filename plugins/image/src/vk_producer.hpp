#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include <vulkan/vulkan.h>

namespace ww_image {

// Image plugin's Vulkan helper.
//
// Slimmed down: no longer owns the export VkImage / VkDeviceMemory /
// dmabuf fd — those live in the bridge pool. VkProducer just manages
// the plugin-side device + a transfer queue + a staging buffer to
// upload RGBA pixels into a bridge-owned VkImage.
class VkProducer {
public:
    ~VkProducer();
    VkProducer(const VkProducer&)            = delete;
    VkProducer& operator=(const VkProducer&) = delete;

    // Set up Vulkan instance/device + a queue with TRANSFER capability,
    // plus a HOST_VISIBLE|COHERENT staging buffer of `width*height*4`
    // bytes pre-mapped for repeated uploads. Image dimensions are
    // baked in so we can size the staging buffer once.
    static std::unique_ptr<VkProducer>
    create(uint32_t width, uint32_t height, std::string* err);

    // Read-only handle accessors (for the bridge pool's Vulkan backend
    // init descriptor and for diagnostics).
    VkInstance       instance() const         { return instance_; }
    VkPhysicalDevice physical_device() const  { return phys_; }
    VkDevice         device() const           { return device_; }
    VkQueue          queue() const            { return queue_; }
    uint32_t         queue_family_index() const { return queue_family_; }
    uint32_t         drm_render_major() const { return drm_render_major_; }
    uint32_t         drm_render_minor() const { return drm_render_minor_; }
    const uint8_t*   device_uuid() const      { return have_uuid_ ? device_uuid_ : nullptr; }
    const uint8_t*   driver_uuid() const      { return have_uuid_ ? driver_uuid_ : nullptr; }
    int              drm_render_fd() const    { return drm_render_fd_; }

    uint32_t         width() const  { return width_; }
    uint32_t         height() const { return height_; }

    // Copy `data` (tightly packed RGBA8, `size` bytes) into the
    // `target` VkImage using staging buffer + transfer queue. Returns
    // an exported sync_fd for the signal semaphore (caller transfers
    // ownership to the bridge pool's submit_slot — bridge closes it
    // after sendmsg). Returns -1 on failure with `*err` populated.
    int upload_into(VkImage target, uint32_t target_width, uint32_t target_height,
                    const uint8_t* data, size_t size, std::string* err);

private:
    VkProducer() = default;

    VkInstance       instance_ { VK_NULL_HANDLE };
    VkPhysicalDevice phys_ { VK_NULL_HANDLE };
    VkDevice         device_ { VK_NULL_HANDLE };
    uint32_t         queue_family_ { 0 };
    VkQueue          queue_ { VK_NULL_HANDLE };

    VkCommandPool    cmd_pool_ { VK_NULL_HANDLE };
    VkCommandBuffer  cmd_ { VK_NULL_HANDLE };
    /* Binary signal semaphore exported as SYNC_FD per-upload — the
     * acquire fence the daemon hands to consumers in frame_ready. */
    VkSemaphore      signal_sem_ { VK_NULL_HANDLE };

    VkBuffer         staging_buf_ { VK_NULL_HANDLE };
    VkDeviceMemory   staging_mem_ { VK_NULL_HANDLE };
    void*            staging_map_ { nullptr };
    VkDeviceSize     staging_size_ { 0 };

    uint32_t         width_ { 0 };
    uint32_t         height_ { 0 };
    uint32_t         drm_render_major_ { 0 };
    uint32_t         drm_render_minor_ { 0 };
    int              drm_render_fd_ { -1 };

    bool             have_uuid_ { false };
    uint8_t          device_uuid_[16] { 0 };
    uint8_t          driver_uuid_[16] { 0 };

    PFN_vkGetSemaphoreFdKHR vkGetSemaphoreFdKHR_ { nullptr };
};

} // namespace ww_image
