/*
		2011 Takahiro Harada
*/

#define PATH "..\\..\\AdlPrimitives\\Scan\\PrefixScanKernels"
#define KERNEL0 "LocalScanKernel"
#define KERNEL1 "TopLevelScanKernel"
#define KERNEL2 "AddOffsetKernel"

#include <AdlPrimitives/Scan/PrefixScanKernelsCL.h>
#include <AdlPrimitives/Scan/PrefixScanKernelsDX11.h>

template<DeviceType TYPE>
typename PrefixScan<TYPE>::Data* PrefixScan<TYPE>::allocate(const Device* device, int maxSize, Option option)
{
	ADLASSERT( TYPE == device->m_type );

	ADLASSERT( maxSize <= BLOCK_SIZE*2*2048 );

	const char* src[] = 
#if defined(ADL_LOAD_KERNEL_FROM_STRING)
		{prefixScanKernelsCL, prefixScanKernelsDX11};
#else
		{0,0};
#endif
	Data* data = new Data;
	data->m_device = device;
	data->m_localScanKernel = device->getKernel( PATH, KERNEL0, 0, src[TYPE] );
	data->m_blockSumKernel = device->getKernel( PATH, KERNEL1, 0, src[TYPE] );
	data->m_propagationKernel = device->getKernel( PATH, KERNEL2, 0, src[TYPE] );
	data->m_workBuffer = new Buffer<u32>( device, (NEXTMULTIPLEOF( max2( maxSize/BLOCK_SIZE, (int)BLOCK_SIZE ), BLOCK_SIZE )+1) );
	data->m_constBuffer[0] = new Buffer<int4>( device, 1, BufferBase::BUFFER_CONST );
	data->m_constBuffer[1] = new Buffer<int4>( device, 1, BufferBase::BUFFER_CONST );
	data->m_constBuffer[2] = new Buffer<int4>( device, 1, BufferBase::BUFFER_CONST );

	data->m_maxSize = maxSize;
	data->m_option = option;

	return data;
}

template<DeviceType TYPE>
void PrefixScan<TYPE>::deallocate(Data* data)
{
	delete data->m_workBuffer;
	delete data->m_constBuffer[0];
	delete data->m_constBuffer[1];
	delete data->m_constBuffer[2];
	delete data;
}

template<DeviceType TYPE>
void PrefixScan<TYPE>::execute(Data* data, Buffer<u32>& src, Buffer<u32>& dst, int n, u32* sum)
{
	ADLASSERT( data );
	ADLASSERT( n <= data->m_maxSize );
	ADLASSERT( data->m_option == EXCLUSIVE );
	const u32 numBlocks = u32( (n+BLOCK_SIZE*2-1)/(BLOCK_SIZE*2) );


	int4 constBuffer;
	constBuffer.x = n;
	constBuffer.y = numBlocks;
	constBuffer.z = (int)nextPowerOf2( numBlocks );

	Buffer<u32>* srcNative = BufferUtils::map<TYPE, true>( data->m_device, &src );
	Buffer<u32>* dstNative = BufferUtils::map<TYPE, false>( data->m_device, &dst );

	{
		BufferInfo bInfo[] = { BufferInfo( dstNative ), BufferInfo( srcNative ), BufferInfo( data->m_workBuffer ) };

		Launcher launcher( data->m_device, data->m_localScanKernel );
		launcher.setBuffers( bInfo, sizeof(bInfo)/sizeof(Launcher::BufferInfo) );
		launcher.setConst( *data->m_constBuffer[0], constBuffer );
		launcher.launch1D( numBlocks*BLOCK_SIZE, BLOCK_SIZE );
	}

	{
		BufferInfo bInfo[] = { BufferInfo( data->m_workBuffer ) };

		Launcher launcher( data->m_device, data->m_blockSumKernel );
		launcher.setBuffers( bInfo, sizeof(bInfo)/sizeof(Launcher::BufferInfo) );
		launcher.setConst( *data->m_constBuffer[1], constBuffer );
		launcher.launch1D( BLOCK_SIZE, BLOCK_SIZE );
	}

	if( sum )
	{
		data->m_workBuffer->read( sum, 1, numBlocks );
	}

	if( numBlocks > 1 )
	{
		BufferInfo bInfo[] = { BufferInfo( dstNative ), BufferInfo( data->m_workBuffer ) };
		Launcher launcher( data->m_device, data->m_propagationKernel );
		launcher.setBuffers( bInfo, sizeof(bInfo)/sizeof(Launcher::BufferInfo) );
		launcher.setConst( *data->m_constBuffer[2], constBuffer );
		launcher.launch1D( (numBlocks-1)*BLOCK_SIZE, BLOCK_SIZE );
	}

	BufferUtils::unmap<false>( srcNative, &src );
	BufferUtils::unmap<true>( dstNative, &dst );
}

#undef PATH
#undef KERNEL0
#undef KERNEL1
#undef KERNEL2
