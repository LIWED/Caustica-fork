package dev.comfyfluffy.caustica.rt.pipeline;

import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.RtDebugLabels;
import dev.comfyfluffy.caustica.rt.offline.OfflineSampleWeights;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.vulkan.VK10;
import org.lwjgl.vulkan.VkCommandBuffer;
import org.lwjgl.vulkan.VkComputePipelineCreateInfo;
import org.lwjgl.vulkan.VkDescriptorImageInfo;
import org.lwjgl.vulkan.VkDescriptorPoolCreateInfo;
import org.lwjgl.vulkan.VkDescriptorPoolSize;
import org.lwjgl.vulkan.VkDescriptorSetAllocateInfo;
import org.lwjgl.vulkan.VkDescriptorSetLayoutBinding;
import org.lwjgl.vulkan.VkDescriptorSetLayoutCreateInfo;
import org.lwjgl.vulkan.VkDevice;
import org.lwjgl.vulkan.VkPipelineLayoutCreateInfo;
import org.lwjgl.vulkan.VkPipelineShaderStageCreateInfo;
import org.lwjgl.vulkan.VkPushConstantRange;
import org.lwjgl.vulkan.VkShaderModuleCreateInfo;
import org.lwjgl.vulkan.VkWriteDescriptorSet;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.LongBuffer;

import static dev.comfyfluffy.caustica.rt.RtContext.check;

/**
 * SPP-weighted progressive HDR accumulation.
 *
 * <p>The current trace and history bindings are RGBA32F; the resolved binding
 * remains RGBA16F for the existing display/exposure path.
 */
public final class RtOfflineAccumulationPipeline {
    private static final String SHADER_DIR = "/caustica/rt/";
    private static final int PUSH_BYTES = 3 * Integer.BYTES;

    private final RtContext ctx;
    private final long descriptorSetLayout;
    private final long descriptorPool;
    private final long descriptorSet;
    private final long pipelineLayout;
    private final long pipeline;
    private long boundCurrentView;
    private long boundHistoryView;
    private long boundResolvedView;
    private boolean destroyed;

    private RtOfflineAccumulationPipeline(RtContext ctx, long descriptorSetLayout,
                                          long descriptorPool, long descriptorSet,
                                          long pipelineLayout, long pipeline) {
        this.ctx = ctx;
        this.descriptorSetLayout = descriptorSetLayout;
        this.descriptorPool = descriptorPool;
        this.descriptorSet = descriptorSet;
        this.pipelineLayout = pipelineLayout;
        this.pipeline = pipeline;
    }

    public static RtOfflineAccumulationPipeline create(RtContext ctx) {
        VkDevice vk = ctx.vk();
        try (MemoryStack stack = MemoryStack.stackPush()) {
            VkDescriptorSetLayoutBinding.Buffer bindings = VkDescriptorSetLayoutBinding.calloc(3, stack);
            for (int i = 0; i < bindings.capacity(); i++) {
                bindings.get(i).binding(i)
                        .descriptorType(VK10.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE)
                        .descriptorCount(1)
                        .stageFlags(VK10.VK_SHADER_STAGE_COMPUTE_BIT);
            }

            VkDescriptorSetLayoutCreateInfo descriptorLayoutInfo =
                    VkDescriptorSetLayoutCreateInfo.calloc(stack).sType$Default().pBindings(bindings);
            LongBuffer handle = stack.mallocLong(1);
            check(VK10.vkCreateDescriptorSetLayout(vk, descriptorLayoutInfo, null, handle),
                    "vkCreateDescriptorSetLayout(offline accumulation)");
            long descriptorSetLayout = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_SET_LAYOUT,
                    descriptorSetLayout, "offline accumulation descriptor set layout");

            VkDescriptorPoolSize.Buffer poolSizes = VkDescriptorPoolSize.calloc(1, stack);
            poolSizes.get(0).type(VK10.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE).descriptorCount(3);
            VkDescriptorPoolCreateInfo poolInfo = VkDescriptorPoolCreateInfo.calloc(stack)
                    .sType$Default().maxSets(1).pPoolSizes(poolSizes);
            check(VK10.vkCreateDescriptorPool(vk, poolInfo, null, handle),
                    "vkCreateDescriptorPool(offline accumulation)");
            long descriptorPool = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_POOL,
                    descriptorPool, "offline accumulation descriptor pool");

            VkDescriptorSetAllocateInfo allocateInfo = VkDescriptorSetAllocateInfo.calloc(stack)
                    .sType$Default()
                    .descriptorPool(descriptorPool)
                    .pSetLayouts(stack.longs(descriptorSetLayout));
            LongBuffer setHandle = stack.mallocLong(1);
            check(VK10.vkAllocateDescriptorSets(vk, allocateInfo, setHandle),
                    "vkAllocateDescriptorSets(offline accumulation)");
            long descriptorSet = setHandle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_SET,
                    descriptorSet, "offline accumulation descriptor set");

            VkPushConstantRange.Buffer pushRange = VkPushConstantRange.calloc(1, stack);
            pushRange.get(0).stageFlags(VK10.VK_SHADER_STAGE_COMPUTE_BIT)
                    .offset(0).size(PUSH_BYTES);
            VkPipelineLayoutCreateInfo pipelineLayoutInfo = VkPipelineLayoutCreateInfo.calloc(stack)
                    .sType$Default()
                    .pSetLayouts(stack.longs(descriptorSetLayout))
                    .pPushConstantRanges(pushRange);
            check(VK10.vkCreatePipelineLayout(vk, pipelineLayoutInfo, null, handle),
                    "vkCreatePipelineLayout(offline accumulation)");
            long pipelineLayout = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE_LAYOUT,
                    pipelineLayout, "offline accumulation pipeline layout");

            long module = loadModule(vk, stack, "offline_accumulate.comp.spv");
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_SHADER_MODULE,
                    module, "offline accumulation shader module");
            VkPipelineShaderStageCreateInfo stage = VkPipelineShaderStageCreateInfo.calloc(stack)
                    .sType$Default()
                    .stage(VK10.VK_SHADER_STAGE_COMPUTE_BIT)
                    .module(module)
                    .pName(stack.UTF8("main"));
            VkComputePipelineCreateInfo.Buffer pipelineInfo = VkComputePipelineCreateInfo.calloc(1, stack);
            pipelineInfo.get(0).sType$Default().stage(stage).layout(pipelineLayout);
            LongBuffer pipelineHandle = stack.mallocLong(1);
            check(VK10.vkCreateComputePipelines(vk, VK10.VK_NULL_HANDLE,
                            pipelineInfo, null, pipelineHandle),
                    "vkCreateComputePipelines(offline accumulation)");
            long pipeline = pipelineHandle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE,
                    pipeline, "offline accumulation compute pipeline");
            VK10.vkDestroyShaderModule(vk, module, null);

            return new RtOfflineAccumulationPipeline(ctx, descriptorSetLayout,
                    descriptorPool, descriptorSet, pipelineLayout, pipeline);
        }
    }

    public void setImages(long currentView, long historyView, long resolvedView) {
        if (boundCurrentView == currentView
                && boundHistoryView == historyView
                && boundResolvedView == resolvedView) {
            return;
        }
        try (MemoryStack stack = MemoryStack.stackPush()) {
            VkDescriptorImageInfo.Buffer currentInfo = imageInfo(stack, currentView);
            VkDescriptorImageInfo.Buffer historyInfo = imageInfo(stack, historyView);
            VkDescriptorImageInfo.Buffer resolvedInfo = imageInfo(stack, resolvedView);
            VkWriteDescriptorSet.Buffer writes = VkWriteDescriptorSet.calloc(3, stack);
            writeStorageImage(writes.get(0), descriptorSet, 0, currentInfo);
            writeStorageImage(writes.get(1), descriptorSet, 1, historyInfo);
            writeStorageImage(writes.get(2), descriptorSet, 2, resolvedInfo);
            VK10.vkUpdateDescriptorSets(ctx.vk(), writes, null);
        }
        boundCurrentView = currentView;
        boundHistoryView = historyView;
        boundResolvedView = resolvedView;
    }

    public void dispatch(VkCommandBuffer cmd, int width, int height,
                         long previousSamples, int currentSamples, boolean resetHistory) {
        OfflineSampleWeights weights =
                OfflineSampleWeights.of(previousSamples, currentSamples, resetHistory);
        try (MemoryStack stack = MemoryStack.stackPush();
             RtDebugLabels.Scope ignored = RtDebugLabels.scope(ctx, cmd, "offline accumulation compute")) {
            VK10.vkCmdBindPipeline(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
            VK10.vkCmdBindDescriptorSets(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE,
                    pipelineLayout, 0, stack.longs(descriptorSet), null);
            ByteBuffer push = stack.malloc(PUSH_BYTES);
            push.putInt(0, weights.previousSamples());
            push.putInt(4, weights.currentSamples());
            push.putInt(8, resetHistory ? 1 : 0);
            VK10.vkCmdPushConstants(cmd, pipelineLayout,
                    VK10.VK_SHADER_STAGE_COMPUTE_BIT, 0, push);
            VK10.vkCmdDispatch(cmd, (width + 15) / 16, (height + 15) / 16, 1);
        }
    }

    public void destroy() {
        if (destroyed) {
            return;
        }
        VkDevice vk = ctx.vk();
        VK10.vkDestroyPipeline(vk, pipeline, null);
        VK10.vkDestroyPipelineLayout(vk, pipelineLayout, null);
        VK10.vkDestroyDescriptorPool(vk, descriptorPool, null);
        VK10.vkDestroyDescriptorSetLayout(vk, descriptorSetLayout, null);
        destroyed = true;
    }

    private static VkDescriptorImageInfo.Buffer imageInfo(MemoryStack stack, long view) {
        VkDescriptorImageInfo.Buffer info = VkDescriptorImageInfo.calloc(1, stack);
        info.get(0).imageView(view).imageLayout(VK10.VK_IMAGE_LAYOUT_GENERAL);
        return info;
    }

    private static void writeStorageImage(VkWriteDescriptorSet write, long set, int binding,
                                          VkDescriptorImageInfo.Buffer imageInfo) {
        write.sType$Default()
                .dstSet(set)
                .dstBinding(binding)
                .descriptorCount(1)
                .descriptorType(VK10.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE)
                .pImageInfo(imageInfo);
    }

    private static long loadModule(VkDevice vk, MemoryStack stack, String name) {
        byte[] bytes;
        try (InputStream input =
                     RtOfflineAccumulationPipeline.class.getResourceAsStream(SHADER_DIR + name)) {
            if (input == null) {
                throw new IllegalStateException("missing SPIR-V resource: " + SHADER_DIR + name);
            }
            bytes = input.readAllBytes();
        } catch (IOException e) {
            throw new IllegalStateException("failed to read SPIR-V resource: " + SHADER_DIR + name, e);
        }

        ByteBuffer code = MemoryUtil.memAlloc(bytes.length).put(bytes);
        code.flip();
        try {
            VkShaderModuleCreateInfo moduleInfo =
                    VkShaderModuleCreateInfo.calloc(stack).sType$Default().pCode(code);
            LongBuffer module = stack.mallocLong(1);
            check(VK10.vkCreateShaderModule(vk, moduleInfo, null, module),
                    "vkCreateShaderModule(" + name + ")");
            return module.get(0);
        } finally {
            MemoryUtil.memFree(code);
        }
    }
}
