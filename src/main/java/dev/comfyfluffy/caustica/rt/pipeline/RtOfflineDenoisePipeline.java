package dev.comfyfluffy.caustica.rt.pipeline;

import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.RtDebugLabels;
import com.mojang.blaze3d.vulkan.VulkanCommandEncoder;
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

/** Two adaptive display-only passes; immutable descriptors never bind raw history for writes. */
public final class RtOfflineDenoisePipeline {
    private static final String SHADER_DIR = "/caustica/rt/";
    private static final int PUSH_BYTES = 4 * Integer.BYTES;

    private final RtContext ctx;
    private final long descriptorSetLayout;
    private final long descriptorPool;
    private final long[] descriptorSets;
    private final long pipelineLayout;
    private final long pipeline;
    private boolean destroyed;

    private RtOfflineDenoisePipeline(RtContext ctx, long descriptorSetLayout,
                                          long descriptorPool, long[] descriptorSets,
                                          long pipelineLayout, long pipeline) {
        this.ctx = ctx;
        this.descriptorSetLayout = descriptorSetLayout;
        this.descriptorPool = descriptorPool;
        this.descriptorSets = descriptorSets;
        this.pipelineLayout = pipelineLayout;
        this.pipeline = pipeline;
    }

    public static RtOfflineDenoisePipeline create(RtContext ctx, long history, long scratchA,
            long moments, long resolved, long normal, long albedo, long depth, long specular) {
        VkDevice vk = ctx.vk();
        long descriptorSetLayout = 0L;
        long descriptorPool = 0L;
        long pipelineLayout = 0L;
        long pipeline = 0L;
        long module = 0L;
        try (MemoryStack stack = MemoryStack.stackPush()) {
            VkDescriptorSetLayoutBinding.Buffer bindings = VkDescriptorSetLayoutBinding.calloc(9, stack);
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
                    "vkCreateDescriptorSetLayout(offline display denoise)");
            descriptorSetLayout = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_SET_LAYOUT,
                    descriptorSetLayout, "offline display denoise descriptor set layout");

            VkDescriptorPoolSize.Buffer poolSizes = VkDescriptorPoolSize.calloc(1, stack);
            poolSizes.get(0).type(VK10.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE).descriptorCount(18);
            VkDescriptorPoolCreateInfo poolInfo = VkDescriptorPoolCreateInfo.calloc(stack)
                    .sType$Default().maxSets(2).pPoolSizes(poolSizes);
            check(VK10.vkCreateDescriptorPool(vk, poolInfo, null, handle),
                    "vkCreateDescriptorPool(offline display denoise)");
            descriptorPool = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_POOL,
                    descriptorPool, "offline display denoise descriptor pool");

            VkDescriptorSetAllocateInfo allocateInfo = VkDescriptorSetAllocateInfo.calloc(stack)
                    .sType$Default()
                    .descriptorPool(descriptorPool)
                    .pSetLayouts(stack.longs(descriptorSetLayout, descriptorSetLayout));
            LongBuffer setHandle = stack.mallocLong(2);
            check(VK10.vkAllocateDescriptorSets(vk, allocateInfo, setHandle),
                    "vkAllocateDescriptorSets(offline display denoise)");
            long[] descriptorSets = {setHandle.get(0), setHandle.get(1)};
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_SET,
                    descriptorSets[0], "offline display denoise descriptor set");

            VkPushConstantRange.Buffer pushRange = VkPushConstantRange.calloc(1, stack);
            pushRange.get(0).stageFlags(VK10.VK_SHADER_STAGE_COMPUTE_BIT)
                    .offset(0).size(PUSH_BYTES);
            VkPipelineLayoutCreateInfo pipelineLayoutInfo = VkPipelineLayoutCreateInfo.calloc(stack)
                    .sType$Default()
                    .pSetLayouts(stack.longs(descriptorSetLayout))
                    .pPushConstantRanges(pushRange);
            check(VK10.vkCreatePipelineLayout(vk, pipelineLayoutInfo, null, handle),
                    "vkCreatePipelineLayout(offline display denoise)");
            pipelineLayout = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE_LAYOUT,
                    pipelineLayout, "offline display denoise pipeline layout");

            module = loadModule(vk, stack, "offline_denoise.comp.spv");
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_SHADER_MODULE,
                    module, "offline display denoise shader module");
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
                    "vkCreateComputePipelines(offline display denoise)");
            pipeline = pipelineHandle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE,
                    pipeline, "offline display denoise compute pipeline");

            RtOfflineDenoisePipeline result = new RtOfflineDenoisePipeline(ctx, descriptorSetLayout,
                    descriptorPool, descriptorSets, pipelineLayout, pipeline);
            result.bindImages(history, scratchA, moments, resolved, normal, albedo, depth, specular);
            return result;
        } catch (RuntimeException | Error failure) {
            if (pipeline != 0L) VK10.vkDestroyPipeline(vk, pipeline, null);
            if (pipelineLayout != 0L) VK10.vkDestroyPipelineLayout(vk, pipelineLayout, null);
            if (descriptorPool != 0L) VK10.vkDestroyDescriptorPool(vk, descriptorPool, null);
            if (descriptorSetLayout != 0L) VK10.vkDestroyDescriptorSetLayout(vk, descriptorSetLayout, null);
            throw failure;
        } finally {
            if (module != 0L) VK10.vkDestroyShaderModule(vk, module, null);
        }
    }

    private void bindImages(long history, long scratchA, long moments, long resolved,
                            long normal, long albedo, long depth, long specular) {
        long[] inputs = {history, scratchA};
        long[] outputs = {scratchA, scratchA};
        try (MemoryStack stack = MemoryStack.stackPush()) {
            for (int pass = 0; pass < 2; pass++) {
                long[] views = {inputs[pass], outputs[pass], resolved, normal, albedo, depth, specular, moments, history};
                VkWriteDescriptorSet.Buffer writes = VkWriteDescriptorSet.calloc(9, stack);
                for (int binding = 0; binding < 9; binding++) {
                    writeStorageImage(writes.get(binding), descriptorSets[pass], binding,
                            imageInfo(stack, views[binding]));
                }
                VK10.vkUpdateDescriptorSets(ctx.vk(), writes, null);
            }
        }
    }

    public void dispatch(VkCommandBuffer cmd, int width, int height,
                         long previousSamples, int currentSamples, boolean resetHistory) {
        OfflineSampleWeights weights = OfflineSampleWeights.of(previousSamples, currentSamples, resetHistory);
        try (MemoryStack stack = MemoryStack.stackPush()) {
            VK10.vkCmdBindPipeline(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
            ByteBuffer push = stack.malloc(PUSH_BYTES);
            for (int pass = 0; pass < 2; pass++) {
                VK10.vkCmdBindDescriptorSets(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE,
                        pipelineLayout, 0, stack.longs(descriptorSets[pass]), null);
                push.putInt(0, pass == 0 ? 0 : 1);
                push.putInt(4, 1);
                push.putInt(8, pass == 1 ? 1 : 0);
                push.putInt(12, weights.previousSamples() + weights.currentSamples());
                VK10.vkCmdPushConstants(cmd, pipelineLayout,
                        VK10.VK_SHADER_STAGE_COMPUTE_BIT, 0, push);
                VK10.vkCmdDispatch(cmd, (width + 15) / 16, (height + 15) / 16, 1);
                VulkanCommandEncoder.memoryBarrier(cmd, stack);
            }
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
                     RtOfflineDenoisePipeline.class.getResourceAsStream(SHADER_DIR + name)) {
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
