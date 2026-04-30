#include "vk_producer.hpp"

#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <vector>

namespace ww_image {

namespace {

bool fail(std::string* err, std::string msg) {
    if (err) *err = std::move(msg);
    return false;
}

const char* vk_result_str(VkResult r) {
    switch (r) {
    case VK_SUCCESS:                        return "VK_SUCCESS";
    case VK_ERROR_OUT_OF_HOST_MEMORY:       return "VK_ERROR_OUT_OF_HOST_MEMORY";
    case VK_ERROR_OUT_OF_DEVICE_MEMORY:     return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
    case VK_ERROR_INITIALIZATION_FAILED:    return "VK_ERROR_INITIALIZATION_FAILED";
    case VK_ERROR_LAYER_NOT_PRESENT:        return "VK_ERROR_LAYER_NOT_PRESENT";
    case VK_ERROR_EXTENSION_NOT_PRESENT:    return "VK_ERROR_EXTENSION_NOT_PRESENT";
    case VK_ERROR_FEATURE_NOT_PRESENT:      return "VK_ERROR_FEATURE_NOT_PRESENT";
    case VK_ERROR_INCOMPATIBLE_DRIVER:      return "VK_ERROR_INCOMPATIBLE_DRIVER";
    case VK_ERROR_DEVICE_LOST:              return "VK_ERROR_DEVICE_LOST";
    case VK_ERROR_FORMAT_NOT_SUPPORTED:     return "VK_ERROR_FORMAT_NOT_SUPPORTED";
    default:                                return "VK_ERROR_?";
    }
}

bool device_has_ext(VkPhysicalDevice phys, const char* name) {
    uint32_t n = 0;
    vkEnumerateDeviceExtensionProperties(phys, nullptr, &n, nullptr);
    std::vector<VkExtensionProperties> props(n);
    vkEnumerateDeviceExtensionProperties(phys, nullptr, &n, props.data());
    for (auto& p : props) {
        if (std::strcmp(p.extensionName, name) == 0) return true;
    }
    return false;
}

bool pick_queue_family(VkPhysicalDevice phys, uint32_t* out) {
    uint32_t n = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &n, nullptr);
    std::vector<VkQueueFamilyProperties> q(n);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &n, q.data());
    for (uint32_t i = 0; i < n; ++i) {
        if (q[i].queueFlags
            & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT
               | VK_QUEUE_TRANSFER_BIT)) {
            *out = i;
            return true;
        }
    }
    return false;
}

} // namespace


VkProducer::~VkProducer() {
    if (device_ != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(device_);
        if (staging_map_)         vkUnmapMemory(device_, staging_mem_);
        if (staging_buf_)         vkDestroyBuffer(device_, staging_buf_, nullptr);
        if (staging_mem_)         vkFreeMemory(device_, staging_mem_, nullptr);
        if (signal_sem_)          vkDestroySemaphore(device_, signal_sem_, nullptr);
        if (cmd_pool_)            vkDestroyCommandPool(device_, cmd_pool_, nullptr);
        vkDestroyDevice(device_, nullptr);
    }
    if (instance_)         vkDestroyInstance(instance_, nullptr);
    if (drm_render_fd_ >= 0) ::close(drm_render_fd_);
}

std::unique_ptr<VkProducer>
VkProducer::create(uint32_t width, uint32_t height, std::string* err) {
    if (width == 0 || height == 0) {
        fail(err, "VkProducer: width/height must be non-zero");
        return nullptr;
    }

    auto self = std::unique_ptr<VkProducer>(new VkProducer());
    self->width_ = width;
    self->height_ = height;

    // --- Instance -------------------------------------------------------
    const char* inst_exts[] = {
        VK_KHR_EXTERNAL_MEMORY_CAPABILITIES_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_CAPABILITIES_EXTENSION_NAME,
        VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
    };
    VkApplicationInfo app {};
    app.sType            = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "waywallen-image-renderer";
    app.apiVersion       = VK_API_VERSION_1_1;

    VkInstanceCreateInfo ici {};
    ici.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo        = &app;
    ici.enabledExtensionCount   = static_cast<uint32_t>(std::size(inst_exts));
    ici.ppEnabledExtensionNames = inst_exts;

    if (VkResult r = vkCreateInstance(&ici, nullptr, &self->instance_);
        r != VK_SUCCESS) {
        fail(err, std::string("vkCreateInstance: ") + vk_result_str(r));
        return nullptr;
    }

    // --- Physical device ------------------------------------------------
    uint32_t pd_count = 0;
    vkEnumeratePhysicalDevices(self->instance_, &pd_count, nullptr);
    if (pd_count == 0) {
        fail(err, "no Vulkan physical devices found");
        return nullptr;
    }
    std::vector<VkPhysicalDevice> pds(pd_count);
    vkEnumeratePhysicalDevices(self->instance_, &pd_count, pds.data());

    const char* req_dev_exts[] = {
        VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
        VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
        VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
        VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
    };
    static constexpr const char* DRM_EXT = "VK_EXT_physical_device_drm";
    for (auto pd : pds) {
        bool ok = true;
        for (const char* e : req_dev_exts) {
            if (!device_has_ext(pd, e)) { ok = false; break; }
        }
        if (ok) { self->phys_ = pd; break; }
    }
    if (self->phys_ == VK_NULL_HANDLE) {
        fail(err, "no physical device supports the DMA-BUF export extension set");
        return nullptr;
    }
    bool have_drm_ext = device_has_ext(self->phys_, DRM_EXT);

    if (!pick_queue_family(self->phys_, &self->queue_family_)) {
        fail(err, "no suitable queue family");
        return nullptr;
    }

    // --- Device ---------------------------------------------------------
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci {};
    qci.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = self->queue_family_;
    qci.queueCount       = 1;
    qci.pQueuePriorities = &prio;

    std::vector<const char*> dev_exts(std::begin(req_dev_exts), std::end(req_dev_exts));
    if (have_drm_ext) dev_exts.push_back(DRM_EXT);

    VkDeviceCreateInfo dci {};
    dci.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount    = 1;
    dci.pQueueCreateInfos       = &qci;
    dci.enabledExtensionCount   = static_cast<uint32_t>(dev_exts.size());
    dci.ppEnabledExtensionNames = dev_exts.data();

    if (VkResult r = vkCreateDevice(self->phys_, &dci, nullptr, &self->device_);
        r != VK_SUCCESS) {
        fail(err, std::string("vkCreateDevice: ") + vk_result_str(r));
        return nullptr;
    }
    vkGetDeviceQueue(self->device_, self->queue_family_, 0, &self->queue_);

    self->vkGetSemaphoreFdKHR_ =
        reinterpret_cast<PFN_vkGetSemaphoreFdKHR>(
            vkGetDeviceProcAddr(self->device_, "vkGetSemaphoreFdKHR"));
    if (!self->vkGetSemaphoreFdKHR_) {
        fail(err, "vkGetSemaphoreFdKHR missing");
        return nullptr;
    }

    // --- Identity (UUID + DRM render node) -----------------------------
    auto vkGetPhysicalDeviceProperties2_ =
        reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(
            vkGetInstanceProcAddr(self->instance_,
                                  "vkGetPhysicalDeviceProperties2"));
    if (vkGetPhysicalDeviceProperties2_) {
        VkPhysicalDeviceIDProperties id_props {};
        id_props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES;
        VkPhysicalDeviceDrmPropertiesEXT drm {};
        drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT;
        if (have_drm_ext) id_props.pNext = &drm;
        VkPhysicalDeviceProperties2 props {};
        props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
        props.pNext = &id_props;
        vkGetPhysicalDeviceProperties2_(self->phys_, &props);
        std::memcpy(self->device_uuid_, id_props.deviceUUID, 16);
        std::memcpy(self->driver_uuid_, id_props.driverUUID, 16);
        self->have_uuid_ = true;
        if (have_drm_ext && drm.hasRender) {
            self->drm_render_major_ = static_cast<uint32_t>(drm.renderMajor);
            self->drm_render_minor_ = static_cast<uint32_t>(drm.renderMinor);
        }
    }

    /* Open the matching render node so the bridge pool can use it for
     * the release timeline drm_syncobj. The render node is identified
     * by (major,minor) — since these are the renderer's own numbers
     * we can cheaply scan /dev/dri/renderD12X and stat() until match. */
    if (self->drm_render_minor_ != 0) {
        for (int i = 128; i < 192; ++i) {
            char path[64];
            std::snprintf(path, sizeof(path), "/dev/dri/renderD%d", i);
            int fd = ::open(path, O_RDWR | O_CLOEXEC);
            if (fd >= 0) {
                self->drm_render_fd_ = fd;
                break;
            }
        }
    }

    // --- Command pool + buffer -----------------------------------------
    VkCommandPoolCreateInfo cpi {};
    cpi.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    cpi.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpi.queueFamilyIndex = self->queue_family_;
    if (VkResult r = vkCreateCommandPool(self->device_, &cpi, nullptr,
                                         &self->cmd_pool_);
        r != VK_SUCCESS) {
        fail(err, std::string("vkCreateCommandPool: ") + vk_result_str(r));
        return nullptr;
    }
    VkCommandBufferAllocateInfo cbi {};
    cbi.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbi.commandPool        = self->cmd_pool_;
    cbi.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbi.commandBufferCount = 1;
    if (VkResult r = vkAllocateCommandBuffers(self->device_, &cbi, &self->cmd_);
        r != VK_SUCCESS) {
        fail(err, std::string("vkAllocateCommandBuffers: ") + vk_result_str(r));
        return nullptr;
    }

    // --- Acquire semaphore (binary, exported as SYNC_FD) ---------------
    VkExportSemaphoreCreateInfo exp_sem {};
    exp_sem.sType       = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO;
    exp_sem.handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
    VkSemaphoreCreateInfo sem_ci {};
    sem_ci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    sem_ci.pNext = &exp_sem;
    if (VkResult r = vkCreateSemaphore(self->device_, &sem_ci, nullptr,
                                       &self->signal_sem_);
        r != VK_SUCCESS) {
        fail(err, std::string("vkCreateSemaphore(acquire): ") + vk_result_str(r));
        return nullptr;
    }

    // --- Staging buffer (HOST_VISIBLE|COHERENT, tightly packed RGBA) ---
    const VkDeviceSize tight = VkDeviceSize(width) * height * 4;
    self->staging_size_ = tight;

    VkBufferCreateInfo bci {};
    bci.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size        = tight;
    bci.usage       = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (VkResult r = vkCreateBuffer(self->device_, &bci, nullptr,
                                    &self->staging_buf_);
        r != VK_SUCCESS) {
        fail(err, std::string("vkCreateBuffer(staging): ") + vk_result_str(r));
        return nullptr;
    }
    VkMemoryRequirements bmr {};
    vkGetBufferMemoryRequirements(self->device_, self->staging_buf_, &bmr);
    VkPhysicalDeviceMemoryProperties mprops {};
    vkGetPhysicalDeviceMemoryProperties(self->phys_, &mprops);
    uint32_t host_type = UINT32_MAX;
    for (uint32_t i = 0; i < mprops.memoryTypeCount; ++i) {
        const auto pf = mprops.memoryTypes[i].propertyFlags;
        if ((bmr.memoryTypeBits & (1u << i))
            && (pf & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
            && (pf & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            host_type = i;
            break;
        }
    }
    if (host_type == UINT32_MAX) {
        fail(err, "no HOST_VISIBLE|COHERENT memory type for staging");
        return nullptr;
    }
    VkMemoryAllocateInfo smai {};
    smai.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    smai.allocationSize  = bmr.size;
    smai.memoryTypeIndex = host_type;
    if (VkResult r = vkAllocateMemory(self->device_, &smai, nullptr,
                                      &self->staging_mem_);
        r != VK_SUCCESS) {
        fail(err, std::string("vkAllocateMemory(staging): ") + vk_result_str(r));
        return nullptr;
    }
    if (VkResult r = vkBindBufferMemory(self->device_, self->staging_buf_,
                                        self->staging_mem_, 0);
        r != VK_SUCCESS) {
        fail(err, std::string("vkBindBufferMemory(staging): ") + vk_result_str(r));
        return nullptr;
    }
    if (VkResult r = vkMapMemory(self->device_, self->staging_mem_, 0,
                                 VK_WHOLE_SIZE, 0, &self->staging_map_);
        r != VK_SUCCESS) {
        fail(err, std::string("vkMapMemory(staging): ") + vk_result_str(r));
        return nullptr;
    }

    return self;
}

int VkProducer::upload_into(VkImage target, uint32_t target_w, uint32_t target_h,
                            const uint8_t* data, size_t size, std::string* err) {
    if (target == VK_NULL_HANDLE) { fail(err, "upload_into: target VkImage is null"); return -1; }
    if (size != staging_size_)    { fail(err, "upload_into: size mismatch"); return -1; }

    std::memcpy(staging_map_, data, size);

    if (VkResult r = vkResetCommandBuffer(cmd_, 0); r != VK_SUCCESS) {
        fail(err, std::string("vkResetCommandBuffer: ") + vk_result_str(r));
        return -1;
    }

    VkCommandBufferBeginInfo bi {};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (VkResult r = vkBeginCommandBuffer(cmd_, &bi); r != VK_SUCCESS) {
        fail(err, std::string("vkBeginCommandBuffer: ") + vk_result_str(r));
        return -1;
    }

    /* UNDEFINED → TRANSFER_DST_OPTIMAL. */
    VkImageMemoryBarrier to_dst {};
    to_dst.sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    to_dst.srcAccessMask       = 0;
    to_dst.dstAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT;
    to_dst.oldLayout           = VK_IMAGE_LAYOUT_UNDEFINED;
    to_dst.newLayout           = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    to_dst.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_dst.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_dst.image               = target;
    to_dst.subresourceRange    = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    vkCmdPipelineBarrier(cmd_,
                         VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &to_dst);

    VkBufferImageCopy region {};
    region.bufferOffset                    = 0;
    region.bufferRowLength                 = 0;
    region.bufferImageHeight               = 0;
    region.imageSubresource.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel       = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount     = 1;
    region.imageOffset                     = { 0, 0, 0 };
    region.imageExtent                     = { target_w, target_h, 1 };
    vkCmdCopyBufferToImage(cmd_, staging_buf_, target,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                           1, &region);

    /* TRANSFER_DST_OPTIMAL → GENERAL, release to FOREIGN. */
    VkImageMemoryBarrier to_foreign {};
    to_foreign.sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    to_foreign.srcAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT;
    to_foreign.dstAccessMask       = 0;
    to_foreign.oldLayout           = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    to_foreign.newLayout           = VK_IMAGE_LAYOUT_GENERAL;
    to_foreign.srcQueueFamilyIndex = queue_family_;
    to_foreign.dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT;
    to_foreign.image               = target;
    to_foreign.subresourceRange    = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    vkCmdPipelineBarrier(cmd_,
                         VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &to_foreign);

    if (VkResult r = vkEndCommandBuffer(cmd_); r != VK_SUCCESS) {
        fail(err, std::string("vkEndCommandBuffer: ") + vk_result_str(r));
        return -1;
    }

    VkSubmitInfo si {};
    si.sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount   = 1;
    si.pCommandBuffers      = &cmd_;
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores    = &signal_sem_;
    if (VkResult r = vkQueueSubmit(queue_, 1, &si, VK_NULL_HANDLE); r != VK_SUCCESS) {
        fail(err, std::string("vkQueueSubmit: ") + vk_result_str(r));
        return -1;
    }

    /* Export sync_file fd. Consumes the semaphore's signal payload so
     * it's reusable on the next upload. */
    VkSemaphoreGetFdInfoKHR sgfi {};
    sgfi.sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
    sgfi.semaphore  = signal_sem_;
    sgfi.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
    int sync_fd = -1;
    if (VkResult r = vkGetSemaphoreFdKHR_(device_, &sgfi, &sync_fd);
        r != VK_SUCCESS) {
        fail(err, std::string("vkGetSemaphoreFdKHR: ") + vk_result_str(r));
        return -1;
    }
    return sync_fd;
}

} // namespace ww_image
