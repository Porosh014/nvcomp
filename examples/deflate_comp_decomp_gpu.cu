/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

 #include "BatchData.h"
 #include "zlib.h"
 #include "libdeflate.h"
 #include "nvcomp/deflate.h"

 extern "C" {

    typedef struct {
        char* data;
        size_t* sizes;
        size_t size;
    } CharVector;

    char* concatenateStrings(const std::vector<char*>& stringVector, std::vector<size_t> compressed_sizes_host) {
        // Calculate the total length needed for the concatenated string
        size_t totalLength = 0; // 1 for null terminator
        size_t index = 0;

        for(int i=0; i < compressed_sizes_host.size(); i++){
            totalLength += compressed_sizes_host[i];
        }

        std::cout << "pre cout before:: " << totalLength << std::endl;
        // Allocate memory for the concatenated string
        char* result = new char[totalLength];
        
        for (const char* str : stringVector) {
            if(index == 0){
                std::strcpy(result, str);
            }    

            else{
                std::strcat(result, str);
            }

            index++;
        }
        
        return result;
    }

    BatchDataCPU GetBatchDataCPU(const BatchData& batch_data, bool copy_data)
    {
        BatchDataCPU compress_data_cpu(
            batch_data.ptrs(),
            batch_data.sizes(),
            batch_data.data(),
            batch_data.size(),
            copy_data);
        return compress_data_cpu;
    }

    // Benchmark performance from the binary data file fname
    CharVector run_example(CharVector image_vector)
    {
        std::vector<char> host_data(image_vector.data, image_vector.data + image_vector.size);
        std::vector<std::vector<char>> data; 
        std::vector<char*> comp_vector;
        // std::vector<char> host_data = readFile("/home/benchmarker/Downloads/high_res.jpg");
        data.push_back(host_data);

        size_t total_bytes = 0;
        for (const std::vector<char>& part : data) {
            total_bytes += part.size();
        }
        
        std::cout << "----------" << std::endl;
        std::cout << "files: " << data.size() << std::endl;
        std::cout << "uncompressed (B): " << total_bytes << std::endl;
        
        const size_t chunk_size = 1 << 16;
        
        // build up metadata
        BatchData input_data(data, chunk_size);
        static nvcompBatchedDeflateOpts_t nvcompBatchedDeflateOpts = {0};
        // Compress on the GPU using batched API
        size_t comp_temp_bytes;
        nvcompStatus_t status = nvcompBatchedDeflateCompressGetTempSize(
            input_data.size(),
            chunk_size,
            nvcompBatchedDeflateOpts,
            &comp_temp_bytes);
        if( status != nvcompSuccess){
            throw std::runtime_error("ERROR: nvcompBatchedDeflateCompressGetTempSize() not successful");
        }
        
        void* d_comp_temp;
        CUDA_CHECK(cudaMalloc(&d_comp_temp, comp_temp_bytes));
        
        size_t max_out_bytes;
        status = nvcompBatchedDeflateCompressGetMaxOutputChunkSize(
            chunk_size, nvcompBatchedDeflateOpts, &max_out_bytes);
        if( status != nvcompSuccess){
            throw std::runtime_error("ERROR: nvcompBatchedDeflateCompressGetMaxOutputChunkSize() not successful");
        }

        BatchData compress_data(max_out_bytes, input_data.size());
        
        cudaStream_t stream;
        cudaStreamCreate(&stream);
        
        cudaEvent_t start, end;
        cudaEventCreate(&start);
        cudaEventCreate(&end);
        cudaEventRecord(start, stream);
        
        status = nvcompBatchedDeflateCompressAsync(
            input_data.ptrs(),
            input_data.sizes(),
            chunk_size,
            input_data.size(),
            d_comp_temp,
            comp_temp_bytes,
            compress_data.ptrs(),
            compress_data.sizes(),
            nvcompBatchedDeflateOpts,
            stream);
        if (status != nvcompSuccess) {
            throw std::runtime_error("nvcompBatchedDeflateCompressAsync() failed.");
        }
        
        cudaEventRecord(end, stream);
        CUDA_CHECK(cudaStreamSynchronize(stream));
        
        // free compression memory
        cudaFree(d_comp_temp);
        
        float ms;
        cudaEventElapsedTime(&ms, start, end);
        
        // compute compression ratio
        std::vector<size_t> compressed_sizes_host(compress_data.size());
        cudaMemcpy(
            compressed_sizes_host.data(),
            compress_data.sizes(),
            compress_data.size() * sizeof(*compress_data.sizes()),
            cudaMemcpyDeviceToHost);
        
        size_t comp_bytes = 0;
        for (const size_t s : compressed_sizes_host) {
            comp_bytes += s;
        }
        
        std::cout << "comp_size: " << comp_bytes
                    << ", compressed ratio: " << std::fixed << std::setprecision(2)
                    << (double)total_bytes / comp_bytes << std::endl;
        std::cout << "compression throughput (GB/s): "
                    << (double)total_bytes / (1.0e6 * ms) << std::endl;
        
        // Allocate and prepare output/compressed batch
        BatchDataCPU compress_data_cpu = GetBatchDataCPU(compress_data, true);

        
        //    BatchDataCPU decompress_data_cpu = GetBatchDataCPU(input_data, false);

        //    // loop over chunks on the CPU, decompressing each one
        //    for (size_t i = 0; i < input_data.size(); ++i) {
        //      if(algo==0){
        //          struct libdeflate_decompressor  *decompressor;
        //          decompressor = libdeflate_alloc_decompressor();
        //          enum libdeflate_result res = libdeflate_deflate_decompress(decompressor, compress_data_cpu.ptrs()[i], compress_data_cpu.sizes()[i], 
        //                                                     decompress_data_cpu.ptrs()[i], decompress_data_cpu.sizes()[i], NULL);
            
        //         if (res != LIBDEFLATE_SUCCESS) {
        //         throw std::runtime_error(
        //             "libdeflate CPU failed to decompress chunk " + std::to_string(i) + ".");
        //         }
        //      }else if (algo==1){
        //          z_stream zs1;
        //          zs1.zalloc = NULL;
        //          zs1.zfree = NULL;
        //          zs1.msg = NULL;
        //          zs1.next_in = (Bytef*)compress_data_cpu.ptrs()[i];
        //          zs1.avail_in = compress_data_cpu.sizes()[i];
        //          zs1.next_out = (Bytef*)decompress_data_cpu.ptrs()[i];
        //          zs1.avail_out = decompress_data_cpu.sizes()[i];
        
        //          int ret = inflateInit2(&zs1, -15);
        //          if (ret != Z_OK) {
        //             throw std::runtime_error("inflateInit2 error " + std::to_string(ret));
        //          }
        //          if ((ret = inflate(&zs1, Z_FINISH)) != Z_STREAM_END) {
        //             throw std::runtime_error("zlib::inflate operation fail " + std::to_string(ret));;
        //              if ((ret = inflateEnd(&zs1)) != Z_OK) {
        //                 throw std::runtime_error("Call to inflateEnd failed: " + std::to_string(ret));
        //              }
        //          }
        //          if ((ret = inflateEnd(&zs1)) != Z_OK) {
        //             throw std::runtime_error("Call to inflateEnd failed: " + std::to_string(ret));
        //          }
        //      }
        //    }
        //    // Validate decompressed data against input
        //    if (!(decompress_data_cpu == input_data))
        //      throw std::runtime_error("Failed to validate CPU decompressed data");
        //    else
        //      std::cout << "CPU decompression validated :)" << std::endl;

        CharVector example_data;
        example_data.data = new char[comp_bytes];
        example_data.sizes = new size_t[compress_data_cpu.size()];
        example_data.size = comp_bytes;

        for(int i=0; i < compress_data_cpu.size(); i++){
            
            // std::cout << "compressed data size:: " <<  << std::endl;

            // if(i == 0){
            //     std::strcpy(example_data.data, static_cast<const char*>(compress_data_cpu.ptrs()[i]));
            // }
            // else{
            //     std::strcat(example_data.data, static_cast<const char*>(compress_data_cpu.ptrs()[i]));
            // }
            
            
            char* tmp_data = static_cast<char*>(compress_data_cpu.ptrs()[i]);
            comp_vector.push_back(tmp_data);
            
            example_data.sizes[i] = compress_data_cpu.sizes()[i];
        }

        cudaEventDestroy(start);
        cudaEventDestroy(end);
        cudaStreamDestroy(stream);

        // example_data.data = concatenateStrings(comp_vector, compressed_sizes_host);

        example_data.data = concatenateStrings(comp_vector, compressed_sizes_host);
        return example_data;
    }

    void run_decompression(CharVector compressed_vector){
        
        size_t total_bytes = 0;
        std::vector<char> host_data(compressed_vector.data, compressed_vector.data + compressed_vector.size);
        std::vector<std::vector<char>> data; 

        data.push_back(host_data);

        const size_t chunk_size = 1 << 16;
        size_t input_data_size = 243;

        for(int i=0; i < input_data_size; i++){
            total_bytes += compressed_vector.sizes[i];
        }

        std::cout << "total recalculated bytes:: " << total_bytes << std::endl;
        
        // BatchDataCPU compressed_data_cpu(data, chunk_size, true);

        
    }
 }